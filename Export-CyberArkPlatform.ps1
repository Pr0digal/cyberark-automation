
# --- Configuration ---
$pvwaUrl = "https://your-pvwa-url"  # e.g., https://cyberark.company.com
$outputCsv = "cyberark_platforms.csv"

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
$body = @{ username = $username; password = $password } | ConvertTo-Json
$response = Invoke-RestMethod -Uri $authUrl -Method POST -Body $body -ContentType "application/json" -UseBasicParsing -SkipCertificateCheck

if (-not $response) {
    Write-Error "❌ Authentication failed"
    exit 1
}

$token = $response.Trim('"')
$headers = @{ Authorization = $token }

# --- Get platforms ---
$platformsUrl = "$pvwaUrl/PasswordVault/api/platforms"
$platformsResponse = Invoke-RestMethod -Uri $platformsUrl -Headers $headers -Method GET -UseBasicParsing -SkipCertificateCheck

if (-not $platformsResponse.Platforms) {
    Write-Error "❌ Failed to retrieve platform list"
    exit 1
}

# --- Export to CSV ---
$platforms = $platformsResponse.Platforms
$platforms | Select-Object id, PlatformID, CPMType, SafeType, Description |
    Export-Csv -Path $outputCsv -NoTypeInformation -Encoding UTF8

Write-Host "✅ Exported platform details to $outputCsv"

# --- Logoff ---
$logoffUrl = "$pvwaUrl/PasswordVault/API/Auth/Logoff"
Invoke-RestMethod -Uri $logoffUrl -Headers $headers -Method POST -UseBasicParsing -SkipCertificateCheck
