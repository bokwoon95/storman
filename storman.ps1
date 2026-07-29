param(
    [ValidateSet("chrome", "firefox")]
    [string] $Browser = "chrome",

    [switch] $Headless,

    [string] $Tenant = "",

    [string] $Site = "",

    [double] $DelayMin = 2.0,

    [double] $DelayMax = 4.0,

    [double] $AbovePercentageOfSiteQuota = 5.0,

    [long] $AboveSizeBytes = 1000000,

    [int] $MaxDepth = 0,

    [switch] $NoStderr
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
$playwrightBrowserType = if ($Browser -eq "firefox") {
    "Firefox"
} else {
    "Chromium"
}

if ($Tenant -eq "" -or $Site -eq "") {
    [Console]::Error.WriteLine("both -Tenant and -Site must be provided")
    exit 1
}
if ($DelayMin -lt 0 -or $DelayMax -lt $DelayMin) {
    [Console]::Error.WriteLine(
        "-DelayMin must be non-negative and no greater than -DelayMax"
    )
    exit 1
}

# Auto-bootstrap PSPlaywright if it isn't installed.
if (-not (Get-Module -ListAvailable -Name PSPlaywright)) {
    [Console]::Error.WriteLine("Installing required module 'PSPlaywright'...")
    $null = Install-Module `
        -Name PSPlaywright `
        -Scope CurrentUser `
        -Force `
        -AllowClobber
}

# Import module.
$null = Import-Module PSPlaywright

# Start Playwright, installing its browser binaries if startup fails.
try {
    $null = Start-Playwright -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine(
        "Downloading Playwright browser binaries..."
    )
    if (
        (Get-Command Install-Playwright).Parameters.ContainsKey("BrowserType")
    ) {
        $installOutput = @(
            Install-Playwright -BrowserType $playwrightBrowserType *>&1
        )
    } else {
        $installOutput = @(Install-Playwright *>&1)
    }
    foreach ($line in $installOutput) {
        [Console]::Error.WriteLine([string] $line)
    }
    $null = Start-Playwright
}

class SharePointFile {
    [datetime] $CrawlDate
    [string] $StormanUrl = ""
    [string] $Path = ""
    [int] $Depth = 0
    [string] $LargeAncestorDetails = ""
    [string] $Type = ""
    [string] $Name = ""
    [string] $TotalSize = ""
    [string] $PercentageOfParent = ""
    [string] $PercentageOfSiteQuota = ""
    [string] $LastModified = ""
    [string] $Details = ""

    SharePointFile() {
        $this.CrawlDate = [DateTimeOffset]::FromUnixTimeSeconds(0).UtcDateTime
    }
}

function Write-StormanRow {
    param([SharePointFile] $File)

    $type = $File.Type.ToLowerInvariant()
    if ($type.Contains("web")) {
        $type = "Web"
    } elseif ($type.Contains("folder")) {
        $type = "Folder"
    } elseif ($type.Contains("file")) {
        $type = "File"
    }

    $fields = [string[]] @(
        $File.CrawlDate.ToString("yyyy-MM-dd HH:mm:ss"),
        $File.Path,
        $type,
        $File.Name,
        $File.TotalSize,
        $File.PercentageOfParent,
        $File.PercentageOfSiteQuota,
        $File.LastModified,
        $File.Details
    )
    for ($i = 0; $i -lt $fields.Length; $i++) {
        if (
            $fields[$i].Contains('"') -or
            $fields[$i].Contains(",") -or
            $fields[$i].Contains("`r") -or
            $fields[$i].Contains("`n")
        ) {
            $fields[$i] = '"' + $fields[$i].Replace('"', '""') + '"'
        }
    }
    [Console]::Out.WriteLine([string]::Join(",", $fields))
}

function ConvertFrom-DataSize {
    param([string] $Size)

    $units = @{
        B = [long] 1
        KB = [long] 1000
        MB = [long] 1000000
        GB = [long] 1000000000
        TB = [long] 1000000000000
        PB = [long] 1000000000000000
        EB = [long] 1000000000000000000
    }
    $segments = $Size.Replace("<", "").Replace(",", "").Trim().Split(
        [char[]] @(" "),
        2,
        [StringSplitOptions]::RemoveEmptyEntries
    )
    $number = [double]::Parse(
        $segments[0],
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture
    )
    if ($segments.Length -eq 1) {
        return [long] [Math]::Round($number)
    }
    return [long] ($number * $units[$segments[1].Trim()])
}

$browserContext = $null
$page = $null
$random = [Random]::new()

try {
    # PSPlaywright's browser cmdlet does not expose persistent contexts, so use
    # the Microsoft.Playwright instance initialized by Start-Playwright.
    $launchOptions =
        [Microsoft.Playwright.BrowserTypeLaunchPersistentContextOptions]::new()
    $launchOptions.Headless = $Headless.IsPresent
    $launchOptions.ViewportSize =
        [Microsoft.Playwright.ViewportSize]::NoViewport
    if ($Browser -eq "chrome") {
        $launchOptions.Channel = "chrome"
        $launchOptions.ChromiumSandbox = $true
        $launchOptions.IgnoreDefaultArgs = [string[]] @(
            "--disable-extensions",
            "--enable-automation"
        )
        $browserType = $PlaywrightContext.Playwright.Chromium
        $profileName = "ChromeProfile"
    } else {
        $browserType = $PlaywrightContext.Playwright.Firefox
        $profileName = "FirefoxProfile"
    }
    $profileDirectory = [IO.Path]::Combine(
        [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::MyDocuments
        ),
        $profileName
    )

    try {
        $browserContext = $browserType.LaunchPersistentContextAsync(
            $profileDirectory,
            $launchOptions
        ).GetAwaiter().GetResult()
    } catch {
        if (-not $NoStderr) {
            [Console]::Error.WriteLine(
                "Browser launch failed; downloading Playwright browser binaries..."
            )
        }
        if (
            (Get-Command Install-Playwright).Parameters.ContainsKey("BrowserType")
        ) {
            $installOutput = @(
                Install-Playwright -BrowserType $playwrightBrowserType *>&1
            )
        } else {
            $installOutput = @(Install-Playwright *>&1)
        }
        foreach ($line in $installOutput) {
            [Console]::Error.WriteLine([string] $line)
        }
        $browserContext = $browserType.LaunchPersistentContextAsync(
            $profileDirectory,
            $launchOptions
        ).GetAwaiter().GetResult()
    }

    $rootFolder = [SharePointFile]::new()
    $rootFolder.StormanUrl = (
        "https://{0}.sharepoint.com/sites/{1}/_layouts/15/storman.aspx" +
        "?root=&OrderBy=0&Asc=0&Page=0"
    ) -f $Tenant, $Site
    $folderQueue = [Collections.Generic.Queue[SharePointFile]]::new()
    $folderQueue.Enqueue($rootFolder)
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )

    if ($browserContext.Pages.Count -gt 0) {
        $page = $browserContext.Pages[0]
    } else {
        $page = $browserContext.NewPageAsync().GetAwaiter().GetResult()
    }
    if (-not $NoStderr) {
        [Console]::Error.WriteLine("page obtained")
    }

    [Console]::Out.WriteLine(
        "Crawl Date,Root,Type,Name,Total Size,% of Parent," +
        "% of Site Quota,Last Modified,Details"
    )

    while ($folderQueue.Count -gt 0 -and -not $page.IsClosed) {
        $folder = $folderQueue.Dequeue()

        if (-not $seenPaths.Add($folder.Path)) {
            continue
        }

        if ($folder.Path -ne "") {
            $delay = $DelayMin + $random.NextDouble() * ($DelayMax - $DelayMin)
            [Threading.Thread]::Sleep([int] ($delay * 1000))
        }

        $nextUrl = $folder.StormanUrl

        while ($nextUrl -ne "" -and -not $page.IsClosed) {
            if (-not $NoStderr) {
                [Console]::Error.WriteLine(
                    "{0} visiting {1}",
                    [datetime]::Now.ToString("yyyy-MM-dd HH:mm:ss"),
                    $nextUrl
                )
            }

            $gotoOptions = [Microsoft.Playwright.PageGotoOptions]::new()
            $gotoOptions.WaitUntil =
                [Microsoft.Playwright.WaitUntilState]::DOMContentLoaded
            $gotoOptions.Timeout = 120000
            $response = $page.GotoAsync(
                $nextUrl,
                $gotoOptions
            ).GetAwaiter().GetResult()

            if (
                $page.Url.StartsWith(
                    "https://login.microsoftonline.com/",
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                if (-not $NoStderr) {
                    [Console]::Error.WriteLine("please complete the login flow")
                }
                if (-not $Headless) {
                    while (-not $page.IsClosed) {
                        [Threading.Thread]::Sleep(250)
                    }
                }
                return
            }

            if ($null -ne $response -and $response.Status -ge 400) {
                $errorFile = [SharePointFile]::new()
                $errorFile.Path = $folder.Path
                $errorFile.Details = "{0}: HTTP {1}" -f $nextUrl, $response.Status
                Write-StormanRow $errorFile
                break
            }

            $nextUrl = ""

            $table = $page.Locator("#onetidUserRptrTable")
            $waitOptions = [Microsoft.Playwright.LocatorWaitForOptions]::new()
            $waitOptions.State = [Microsoft.Playwright.WaitForSelectorState]::Visible
            $waitOptions.Timeout = 120000
            $null = $table.WaitForAsync($waitOptions).GetAwaiter().GetResult()

            $rows = Invoke-PlaywrightPageJavascript -Page $page -Expression @'
() => {
    const rows = [];
    for (const row of document.querySelector("#onetidUserRptrTable").rows) {
        const cells = [];
        for (const cell of row.cells) {
            cells.push({
                href: cell.querySelector("a")?.href ?? null,
                alt_text: cell.querySelector("img")?.alt ?? null,
                text_content: cell.textContent.trim(),
            });
        }
        rows.push(cells);
    }
    return rows;
}
'@

            if ($rows.Count -eq 0) {
                break
            }

            $columnNameSet = [Collections.Generic.HashSet[string]]::new(
                [string[]] @(
                    "Type",
                    "Name",
                    "Total Size",
                    "% Of Parent",
                    "% Of Site Quota",
                    "Last Modified"
                ),
                [StringComparer]::Ordinal
            )
            $indexes = [Collections.Generic.Dictionary[string, int]]::new(
                [StringComparer]::Ordinal
            )
            for ($index = 0; $index -lt $rows[0].Count; $index++) {
                $columnName = [Globalization.CultureInfo]::InvariantCulture.TextInfo.
                    ToTitleCase(
                        [regex]::Replace(
                            $rows[0][$index].text_content,
                            "\s+",
                            " "
                        ).ToLowerInvariant()
                    )
                if ($columnNameSet.Contains($columnName)) {
                    $indexes[$columnName] = $index
                }
            }

            $files = [Collections.Generic.List[SharePointFile]]::new()
            $largeFiles = [Collections.Generic.List[SharePointFile]]::new()

            for ($rowIndex = 1; $rowIndex -lt $rows.Count; $rowIndex++) {
                $row = $rows[$rowIndex]
                if ($row.Count -eq 0) {
                    continue
                }

                $file = [SharePointFile]::new()
                $file.CrawlDate = [datetime]::Now
                $file.StormanUrl = [string] $row[$indexes["Name"]].href
                $file.LargeAncestorDetails = $folder.LargeAncestorDetails
                $file.Type = [string] $row[$indexes["Type"]].alt_text
                $file.Name = [string] $row[$indexes["Name"]].text_content
                $file.TotalSize =
                    [string] $row[$indexes["Total Size"]].text_content
                $file.PercentageOfParent =
                    [string] $row[$indexes["% Of Parent"]].text_content
                $file.PercentageOfSiteQuota =
                    [string] $row[$indexes["% Of Site Quota"]].text_content
                $file.LastModified =
                    [string] $row[$indexes["Last Modified"]].text_content

                $lowerType = $file.Type.ToLowerInvariant()
                if (
                    $lowerType.Contains("folder") -or
                    $lowerType.Contains("file")
                ) {
                    $file.Depth = $folder.Depth + 1
                } else {
                    $file.Depth = $folder.Depth
                }

                if ($file.StormanUrl -ne "") {
                    $uri = [Uri]::new($file.StormanUrl)
                    foreach ($segment in $uri.Query.TrimStart("?").Split("&")) {
                        $pair = $segment.Split("=", 2)
                        if ($pair[0] -eq "root" -and $pair.Length -gt 1) {
                            $file.Path = [Uri]::UnescapeDataString(
                                $pair[1].Replace("+", " ")
                            )
                        }
                    }
                } else {
                    $childName = $file.Name.TrimStart("/")
                    if ($folder.Path -eq "") {
                        $file.Path = $childName
                    } else {
                        $file.Path = $folder.Path.TrimEnd("/") + "/" + $childName
                    }
                }

                try {
                    $percentage = [double]::Parse(
                        $file.PercentageOfSiteQuota.TrimEnd("%"),
                        [Globalization.NumberStyles]::Float,
                        [Globalization.CultureInfo]::InvariantCulture
                    )
                    if ($percentage -ge $AbovePercentageOfSiteQuota) {
                        $largeFiles.Add($file)
                    }
                } catch [FormatException] {
                }

                $files.Add($file)
            }

            if ($folder.LargeAncestorDetails -ne "") {
                foreach ($file in $files) {
                    try {
                        if ((ConvertFrom-DataSize $file.TotalSize) -le $AboveSizeBytes) {
                            continue
                        }
                    } catch {
                        continue
                    }
                    $file.Details = $folder.LargeAncestorDetails
                    Write-StormanRow $file
                    if (
                        $file.StormanUrl -ne "" -and
                        ($MaxDepth -le 0 -or $file.Depth -lt $MaxDepth)
                    ) {
                        $folderQueue.Enqueue($file)
                    }
                    $locator = $page.Locator("a:has(img[alt=Next])")
                    if ($locator.CountAsync().GetAwaiter().GetResult() -gt 0) {
                        $href = $locator.First.GetAttributeAsync(
                            "href"
                        ).GetAwaiter().GetResult()
                        if ($null -eq $href) {
                            $href = ""
                        }
                        $nextUrl = [Uri]::new(
                            [Uri]::new($page.Url),
                            $href
                        ).AbsoluteUri
                    }
                }
            } elseif ($largeFiles.Count -gt 0) {
                foreach ($file in $largeFiles) {
                    try {
                        if ((ConvertFrom-DataSize $file.TotalSize) -le $AboveSizeBytes) {
                            continue
                        }
                    } catch {
                        continue
                    }
                    $file.Details = (
                        "{0}: percentage_of_site_quota {1} ({2}) is above {3}%"
                    ) -f (
                        $file.Path,
                        $file.PercentageOfSiteQuota,
                        $file.TotalSize,
                        $AbovePercentageOfSiteQuota
                    )
                    Write-StormanRow $file
                    if (
                        $file.StormanUrl -ne "" -and
                        ($MaxDepth -le 0 -or $file.Depth -lt $MaxDepth)
                    ) {
                        $folderQueue.Enqueue($file)
                    }
                    if ($largeFiles.Count -eq $files.Count) {
                        $locator = $page.Locator("a:has(img[alt=Next])")
                        if ($locator.CountAsync().GetAwaiter().GetResult() -gt 0) {
                            $href = $locator.First.GetAttributeAsync(
                                "href"
                            ).GetAwaiter().GetResult()
                            if ($null -eq $href) {
                                $href = ""
                            }
                            $nextUrl = [Uri]::new(
                                [Uri]::new($page.Url),
                                $href
                            ).AbsoluteUri
                        }
                    }
                }
            } else {
                foreach ($file in $files) {
                    try {
                        if ((ConvertFrom-DataSize $file.TotalSize) -le $AboveSizeBytes) {
                            continue
                        }
                    } catch {
                        continue
                    }
                    $file.Details = (
                        "belongs to large ancestor: {0} ({1}, {2})"
                    ) -f (
                        $folder.Path,
                        $folder.TotalSize,
                        $folder.PercentageOfSiteQuota
                    )
                    $file.LargeAncestorDetails = $file.Details
                    Write-StormanRow $file
                    if (
                        $file.StormanUrl -ne "" -and
                        ($MaxDepth -le 0 -or $file.Depth -lt $MaxDepth)
                    ) {
                        $folderQueue.Enqueue($file)
                    }
                    $locator = $page.Locator("a:has(img[alt=Next])")
                    if ($locator.CountAsync().GetAwaiter().GetResult() -gt 0) {
                        $href = $locator.First.GetAttributeAsync(
                            "href"
                        ).GetAwaiter().GetResult()
                        if ($null -eq $href) {
                            $href = ""
                        }
                        $nextUrl = [Uri]::new(
                            [Uri]::new($page.Url),
                            $href
                        ).AbsoluteUri
                    }
                }
            }
        }
    }
} catch {
    if ($null -eq $page -or -not $page.IsClosed) {
        throw
    }
} finally {
    if ($null -ne $browserContext) {
        try {
            $browserContext.CloseAsync().GetAwaiter().GetResult()
        } catch {
        }
    }
    try {
        Stop-Playwright
    } catch {
    }
}
