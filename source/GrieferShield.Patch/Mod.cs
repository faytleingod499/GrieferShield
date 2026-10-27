using GDWeave;
using GDWeave.Godot;
using GDWeave.Godot.Variants;
using GDWeave.Modding;
using Serilog;

namespace GrieferShield;

/// <summary>
/// Closes the one hole the GDScript part of Griefer Shield cannot: the decompression bomb.
///
/// The game unpacks every packet it receives with   PACKET.payload.decompress_dynamic( - 1, COMPRESSION_TYPE)
/// in SteamNetwork.gd. The -1 means "no size limit", so a few kilobytes of packet that unpack to gigabytes make the game
/// run out of memory and crash, before any GDScript mod gets to see the packet. This patch changes that -1 into a limit
/// (8 MB, the same limit the Cove server's Packet Guard uses). A packet that would unpack to more than that is refused
/// by the engine and the game carries on.
/// </summary>
public class Mod : IMod {
    public Mod(IModInterface modInterface) {
        modInterface.RegisterScriptMod(new PacketSizeCap(modInterface.Logger));
        modInterface.RegisterScriptMod(new PacketRecorder(modInterface.Logger));
    }

    public void Dispose() { }
}

public class PacketSizeCap(ILogger logger) : IScriptMod {
    // the biggest thing the real game sends is a chalk canvas or the list of actors, far below this
    public const long MaxUnpackedBytes = 8L * 1024 * 1024;

    public bool ShouldRun(string path) => path.Replace('\\', '/').Contains("/Singletons/SteamNetwork.gd");

    public IEnumerable<Token> Modify(string path, IEnumerable<Token> tokens) {
        var all = tokens.ToList();
        var patched = 0;

        for (var i = 0; i < all.Count; i++) {
            // decompress_dynamic ( - 1 ,      (the compiler keeps "-1" as a minus token and a constant 1)
            if (all[i] is IdentifierToken { Name: "decompress_dynamic" }
                && i + 3 < all.Count
                && all[i + 1].Type == TokenType.ParenthesisOpen
                && all[i + 2].Type == TokenType.OpSub
                && all[i + 3] is ConstantToken { Value: IntVariant { Value: 1 } }) {
                yield return all[i];
                yield return all[i + 1];
                yield return new ConstantToken(new IntVariant(MaxUnpackedBytes));
                i += 3;
                patched++;
                continue;
            }

            // the same, if the compiler ever stores it as the constant -1
            if (all[i] is IdentifierToken { Name: "decompress_dynamic" }
                && i + 2 < all.Count
                && all[i + 1].Type == TokenType.ParenthesisOpen
                && all[i + 2] is ConstantToken { Value: IntVariant { Value: -1 } }) {
                yield return all[i];
                yield return all[i + 1];
                yield return new ConstantToken(new IntVariant(MaxUnpackedBytes));
                i += 2;
                patched++;
                continue;
            }

            yield return all[i];
        }

        if (patched > 0) {
            logger.Information("[GrieferShield] packet size limit of {Mb} MB set on {Count} place(s) in {Path}",
                MaxUnpackedBytes / (1024 * 1024), patched, path);
        } else {
            logger.Warning("[GrieferShield] could not find the packet unpacking line in {Path}: the game was probably updated, so decompression bombs are NOT blocked", path);
        }
    }
}

/// <summary>
/// The black box. Adds two calls to the game's packet reader (SteamNetwork.gd, _read_P2P_Packet), both guarded so they do
/// nothing if the Griefer Shield script isn't there:
///
///     (before)  var decomp = PACKET.payload.decompress_dynamic(...)
///   + if has_node("/root/GrieferShield"):
///   +     get_node("/root/GrieferShield").blackbox(PACKET_SENDER, PACKET.payload)
///
///     var type: String = DATA["type"]
///   + if has_node("/root/GrieferShield"):
///   +     get_node("/root/GrieferShield").blackbox_packet(PACKET_SENDER, DATA)
///
/// main.gd writes a line per packet to griefershield_blackbox.log (see the comments there). If either place can't be found
/// exactly once (a game update), nothing at all is added, so the script is never left half patched.
/// </summary>
public class PacketRecorder(ILogger logger) : IScriptMod {
    private const string ShieldNode = "/root/GrieferShield";

    public bool ShouldRun(string path) => path.Replace('\\', '/').Contains("/Singletons/SteamNetwork.gd");

    public IEnumerable<Token> Modify(string path, IEnumerable<Token> tokens) {
        var all = tokens.ToList();

        // the line "var decomp = ..." and the line "var type: String = DATA["type"]"
        var decomp = new List<int>();
        var type = new List<int>();
        for (var i = 1; i + 5 < all.Count; i++) {
            if (all[i].Type != TokenType.PrVar || all[i - 1].Type != TokenType.Newline) continue;
            if (all[i + 1] is IdentifierToken { Name: "decomp" }) decomp.Add(i);
            if (all[i + 1] is IdentifierToken { Name: "type" }
                && all[i + 2].Type == TokenType.Colon
                && all[i + 3].Type == TokenType.BuiltInType
                && all[i + 4].Type == TokenType.OpAssign
                && all[i + 5] is IdentifierToken { Name: "DATA" }) type.Add(i);
        }

        var typeLineEnd = -1;
        if (type.Count == 1) {
            for (var j = type[0]; j < all.Count; j++) {
                if (all[j].Type == TokenType.Newline) {
                    typeLineEnd = j;
                    break;
                }
            }
        }

        if (decomp.Count != 1 || type.Count != 1 || typeLineEnd < 0) {
            logger.Warning("[GrieferShield] could not find the packet reading lines in {Path} (decomp: {A}, type: {B}): the black box is OFF, the game was probably updated", path, decomp.Count, type.Count);
            foreach (var token in all) yield return token;
            yield break;
        }

        var firstIndent = all[decomp[0] - 1].AssociatedData ?? 0;
        var secondIndent = all[type[0] - 1].AssociatedData ?? 0;

        for (var i = 0; i < all.Count; i++) {
            if (i == decomp[0]) {
                foreach (var t in Guarded(firstIndent, "blackbox", [
                    new IdentifierToken("PACKET_SENDER"),
                    new Token(TokenType.Comma),
                    new IdentifierToken("PACKET"),
                    new Token(TokenType.Period),
                    new IdentifierToken("payload")
                ])) yield return t;
                yield return new Token(TokenType.Newline, firstIndent);
            }

            if (i == typeLineEnd) {
                yield return new Token(TokenType.Newline, secondIndent);
                foreach (var t in Guarded(secondIndent, "blackbox_packet", [
                    new IdentifierToken("PACKET_SENDER"),
                    new Token(TokenType.Comma),
                    new IdentifierToken("DATA")
                ])) yield return t;
            }

            yield return all[i];
        }

        logger.Information("[GrieferShield] packet black box added to {Path}", path);
    }

    // if has_node("/root/GrieferShield"):
    //     get_node("/root/GrieferShield").<method>(<args>)
    private static IEnumerable<Token> Guarded(uint indent, string method, Token[] args) {
        yield return new Token(TokenType.CfIf);
        yield return new IdentifierToken("has_node");
        yield return new Token(TokenType.ParenthesisOpen);
        yield return new ConstantToken(new StringVariant(ShieldNode));
        yield return new Token(TokenType.ParenthesisClose);
        yield return new Token(TokenType.Colon);
        yield return new Token(TokenType.Newline, indent + 1);
        yield return new IdentifierToken("get_node");
        yield return new Token(TokenType.ParenthesisOpen);
        yield return new ConstantToken(new StringVariant(ShieldNode));
        yield return new Token(TokenType.ParenthesisClose);
        yield return new Token(TokenType.Period);
        yield return new IdentifierToken(method);
        yield return new Token(TokenType.ParenthesisOpen);
        foreach (var arg in args) yield return arg;
        yield return new Token(TokenType.ParenthesisClose);
    }
}
