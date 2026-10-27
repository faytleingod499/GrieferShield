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
