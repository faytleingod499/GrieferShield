# Zips a folder with forward-slash entry names (what Thunderstore and mod managers expect). Used by build-windows.bat.
param([string]$Stage, [string]$Zip)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $Zip) { Remove-Item $Zip }
$root = (Resolve-Path $Stage).Path.TrimEnd('\')
$archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Create')
try {
    Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
        $name = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $name, 'Optimal')
    }
}
finally {
    $archive.Dispose()
}
