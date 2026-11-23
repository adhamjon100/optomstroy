<#
.SYNOPSIS
  Zip-архив папки с именами записей через «/» (как требует спецификация ZIP). [ПК разработчика]

.DESCRIPTION
  ZipFile.CreateFromDirectory .NET Framework 4.x в Windows PowerShell 5.1 пишет имена записей через «\»
  («apache\apache-common.ps1»): распаковка .NET под Windows это понимает, а unzip Linux, часть архиваторов и
  антивирусов видят плоские имена. Здесь архив собирается по одной записи: относительный путь с «/», пустые
  папки — записями «папка/». Вызывает release\build-release.ps1; проверяет tests\scripts.tests.ps1.

.EXAMPLE
  .\New-ReleaseZip.ps1 -SourceDir .tmp\wn-release\stage\r -ZipPath .tmp\wn-release\Optomstroy-Server-X-win-x64.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$ZipPath
)

$ErrorActionPreference = 'Stop'
$SourceDir = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\')
$ZipPath = [System.IO.Path]::GetFullPath($ZipPath)
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { throw "нет папки $SourceDir" }
if (Test-Path -LiteralPath $ZipPath) { throw "$ZipPath уже есть" }

if (-not ('OptomstroyReleaseZip' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.IO.Compression', 'System.IO.Compression.FileSystem') -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;

public static class OptomstroyReleaseZip
{
    // Возвращает число записей-файлов.
    public static int Create(string sourceDir, string zipPath)
    {
        string root = Path.GetFullPath(sourceDir).TrimEnd('\\') + "\\";
        int files = 0;
        using (FileStream fs = new FileStream(zipPath, FileMode.CreateNew, FileAccess.Write))
        using (ZipArchive zip = new ZipArchive(fs, ZipArchiveMode.Create))
        {
            Add(zip, root, root, ref files);
        }
        return files;
    }

    private static void Add(ZipArchive zip, string root, string dir, ref int files)
    {
        string[] subdirs = Directory.GetDirectories(dir);
        string[] entries = Directory.GetFiles(dir);
        Array.Sort(subdirs, StringComparer.Ordinal);
        Array.Sort(entries, StringComparer.Ordinal);
        if (subdirs.Length == 0 && entries.Length == 0 && !string.Equals(dir, root, StringComparison.OrdinalIgnoreCase))
        {
            zip.CreateEntry(Rel(root, dir).TrimEnd('/') + "/");
            return;
        }
        foreach (string f in entries)
        {
            if ((File.GetAttributes(f) & FileAttributes.ReparsePoint) != 0) throw new IOException("ссылка в релизе не допускается: " + f);
            ZipFileExtensions.CreateEntryFromFile(zip, f, Rel(root, f), CompressionLevel.Optimal);
            files++;
        }
        foreach (string d in subdirs)
        {
            if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) != 0) throw new IOException("ссылка в релизе не допускается: " + d);
            Add(zip, root, d + "\\", ref files);
        }
    }

    private static string Rel(string root, string path)
    {
        return path.Substring(root.Length).Replace('\\', '/');
    }
}
'@
}

$n = [OptomstroyReleaseZip]::Create($SourceDir, $ZipPath)
Write-Output $n
