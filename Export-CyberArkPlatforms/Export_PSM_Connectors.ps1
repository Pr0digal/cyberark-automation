# --- Configuration ---
$pvwaUrl = "https://your-pvwa-url"  # e.g., https://cyberark.company.com
$outputCsv = "cyberark_psm_connectors.csv"

# --- Get credentials from environment or prompt ---
$username = $env:CYBERARK_USER
$password = $env:CYBERARK_PASS

if (-not $username) {
    $username = Read-Host "Enter CyberArk username"
}

if (-not $password) {
    $securePassword = Read-Host "Enter CyberArk password" -AsSecureString
    $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    )
}

# --- Authenticate ---
$authUrl = "$pvwaUrl/PasswordVault/API/Auth/CyberArk/Logon"
$authBody = @{ username = $username; password = $password } | ConvertTo-Json
try {
    $authResponse = Invoke-RestMethod -Uri $authUrl -Method POST -Body $authBody -ContentType "application/json" -SkipCertificateCheck
} catch {
    Write-Error "❌ Authentication request failed: $_"
    exit 1
}

if (-not $authResponse) {
    Write-Error "❌ Authentication failed"
    exit 1
}

$token = $authResponse.Trim('"')
$headers = @{ Authorization = $token }

# --- Fetch all platform IDs ---
$platformsUrl = "$pvwaUrl/PasswordVault/api/platforms"
try {
    $platformList = Invoke-RestMethod -Uri $platformsUrl -Headers $headers -Method GET -SkipCertificateCheck
} catch {
    Write-Error "❌ Failed to retrieve platform list: $_"
    exit 1
}

if (-not $platformList.Platforms) {
    Write-Error "❌ No platforms found"
    exit 1
}

$connectorsData = @()

# --- Loop through each platform to get only PSM-enabled connector details ---
foreach ($platform in $platformList.Platforms) {
    $platformId = $platform.PlatformID
    $platformDetailsUrl = "$pvwaUrl/PasswordVault/api/platforms/$platformId"

    try {
        $platformDetails = Invoke-RestMethod -Uri $platformDetailsUrl -Headers $headers -Method GET -SkipCertificateCheck
    } catch {
        Write-Warning "⚠️ Failed to fetch platform '$platformId': $_"
        continue
    }

    # Only include connection methods with UsePSM = true
    foreach ($method in $platformDetails.ConnectionMethods | Where-Object { $_.UsePSM -eq $true }) {
        $connectorsData += [PSCustomObject]@{
            PlatformID         = $platformId
            PlatformName       = $platformDetails.Name
            ConnectorName      = $method.Name
            ConnectorType      = $method.ConnectionComponent
            Port               = $method.PlatformPort
            UsePSM             = $method.UsePSM
            Description        = $platformDetails.Description
        }
    }
}

# --- Export to CSV ---
$connectorsData | Export-Csv -Path $outputCsv -NoTypeInformation -Encoding UTF8
Write-Host "✅ Exported PSM-enabled connectors to '$outputCsv'"

# --- Logoff ---
$logoffUrl = "$pvwaUrl/PasswordVault/API/Auth/Logoff"
try {
    Invoke-RestMethod -Uri $logoffUrl -Headers $headers -Method POST -SkipCertificateCheck | Out-Null
    Write-Host "🔒 Logged off successfully"
} catch {
    Write-Warning "⚠️ Failed to log off cleanly: $_"
}
