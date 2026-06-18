<#
.SYNOPSIS
Uploads local images or videos as GitHub user attachments and prints Markdown-ready links.

.DESCRIPTION
This uses GitHub's undocumented web upload flow. It is intentionally narrow:
the supported credential sources are a locally configured session or
GH_USER_SESSION. The script does not read browser cookies and does not edit
PRs/issues.

.EXAMPLE
.\gh-upload-image.ps1 configure
.\gh-upload-image.ps1 Eternet/Eternet.Netmap .\screenshot.png
.\gh-upload-image.ps1 Eternet/Eternet.Netmap .\demo.mp4
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Repo,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Path,

    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$script:ConfigDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'gh-user-attachment-upload'
if ([string]::IsNullOrWhiteSpace($script:ConfigDir)) {
    $script:ConfigDir = Join-Path $HOME '.gh-user-attachment-upload'
}
$script:SessionPath = Join-Path $script:ConfigDir 'session.txt'

function Show-Usage {
    @'
Usage:
  gh-upload-image configure
  gh-upload-image owner/repo path\file.ext [path\another.mp4 ...]
  gh-upload-image clear-session

Session:
  Run configure once, or set GH_USER_SESSION for one-off/CI usage.

Output:
  Markdown-ready GitHub user-attachments URLs.
'@
}

function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString] $SecureString
    )

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Save-Session {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Session
    )

    $secure = ConvertTo-SecureString $Session -AsPlainText -Force
    $encrypted = $secure | ConvertFrom-SecureString
    New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    Set-Content -LiteralPath $script:SessionPath -Value $encrypted -Encoding ASCII -NoNewline
}

function Get-SavedSession {
    if (-not (Test-Path -LiteralPath $script:SessionPath)) {
        return $null
    }

    try {
        $encrypted = Get-Content -LiteralPath $script:SessionPath -Raw
        $secure = $encrypted | ConvertTo-SecureString
        return Convert-SecureStringToPlainText $secure
    }
    catch {
        throw "Could not read saved session from $script:SessionPath. Run 'gh-upload-image configure' again."
    }
}

function Resolve-Session {
    $fromEnv = [string] $env:GH_USER_SESSION
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return $fromEnv
    }

    return Get-SavedSession
}

function Invoke-Configure {
    [Console]::Error.WriteLine('Paste the github.com user_session cookie value. Input is hidden and will be saved locally for this OS user.')
    $secure = Read-Host -Prompt 'user_session' -AsSecureString
    $plain = Convert-SecureStringToPlainText $secure
    try {
        if ([string]::IsNullOrWhiteSpace($plain)) {
            [Console]::Error.WriteLine('Session value cannot be empty.')
            exit 2
        }

        Save-Session $plain.Trim()
        Write-Host "Saved session to $script:SessionPath"
    }
    finally {
        if ($null -ne $secure) {
            $secure.Dispose()
        }
    }
}

function Clear-Session {
    if (Test-Path -LiteralPath $script:SessionPath) {
        Remove-Item -LiteralPath $script:SessionPath -Force
    }
    Write-Host "Cleared saved session from $script:SessionPath"
}

if ($Help) {
    Show-Usage
    exit 0
}

$command = if ($null -eq $Repo) { '' } else { $Repo.Trim().ToLowerInvariant() }
if ($command -in @('configure', 'config', 'login')) {
    if ($null -ne $Path -and $Path.Count -gt 0) {
        [Console]::Error.WriteLine('configure does not take file arguments.')
        exit 2
    }
    Invoke-Configure
    exit 0
}

if ($command -in @('clear-session', 'logout')) {
    if ($null -ne $Path -and $Path.Count -gt 0) {
        [Console]::Error.WriteLine('clear-session does not take file arguments.')
        exit 2
    }
    Clear-Session
    exit 0
}

if (
    [string]::IsNullOrWhiteSpace($Repo) -or
    $Repo -notmatch '^[^/]+/[^/]+$' -or
    $null -eq $Path -or
    $Path.Count -eq 0
) {
    [Console]::Error.WriteLine('Invalid arguments.')
    [Console]::Error.WriteLine((Show-Usage | Out-String).TrimEnd())
    exit 2
}

function New-GitHubUploadClient {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Session
    )

    Add-Type -AssemblyName System.Net.Http

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CookieContainer = [System.Net.CookieContainer]::new()
    $handler.AutomaticDecompression =
        [System.Net.DecompressionMethods]::GZip -bor
        [System.Net.DecompressionMethods]::Deflate

    $githubUri = [Uri] 'https://github.com/'
    foreach ($cookieName in @('user_session', '__Host-user_session_same_site')) {
        $cookie = [System.Net.Cookie]::new($cookieName, $Session, '/', 'github.com')
        $cookie.Secure = $true
        $cookie.HttpOnly = $true
        $handler.CookieContainer.Add($githubUri, $cookie)
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    return $client
}

function Add-StringFormField {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.MultipartFormDataContent] $Form,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $content = [System.Net.Http.ByteArrayContent]::new($bytes)
    $Form.Add($content, $Name)
}

function Add-GitHubUploadHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpRequestMessage] $Request,

        [Parameter(Mandatory = $true)]
        [string] $Repo
    )

    $Request.Headers.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
    $Request.Headers.TryAddWithoutValidation('Origin', 'https://github.com') | Out-Null
    $Request.Headers.TryAddWithoutValidation('Referer', "https://github.com/$Repo") | Out-Null
    $Request.Headers.TryAddWithoutValidation('X-Requested-With', 'XMLHttpRequest') | Out-Null
    $Request.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent) | Out-Null
}

function Invoke-HttpRequest {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpRequestMessage] $Request,

        [Parameter(Mandatory = $true)]
        [int[]] $ExpectedStatusCodes,

        [Parameter(Mandatory = $true)]
        [string] $Step
    )

    $response = $Client.SendAsync($Request).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $statusCode = [int] $response.StatusCode

    if ($statusCode -notin $ExpectedStatusCodes) {
        $shortBody = $body
        if ($shortBody.Length -gt 500) {
            $shortBody = $shortBody.Substring(0, 500)
        }
        throw "$Step failed: expected HTTP $($ExpectedStatusCodes -join '/'), got $statusCode. $shortBody"
    }

    return [pscustomobject] @{
        StatusCode = $statusCode
        Body = $body
    }
}

function Get-ContentType {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    switch ([System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()) {
        '.png'  { return 'image/png' }
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.gif'  { return 'image/gif' }
        '.webp' { return 'image/webp' }
        '.bmp'  { return 'image/bmp' }
        '.svg'  { return 'image/svg+xml' }
        '.mp4'  { return 'video/mp4' }
        '.mov'  { return 'video/quicktime' }
        '.webm' { return 'video/webm' }
        default { return 'application/octet-stream' }
    }
}

function Get-RepositoryId {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repo
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required to resolve the repository id.'
    }

    $id = (& gh api "repos/$Repo" --jq .id 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
        throw "Could not resolve repository id for $Repo through gh api."
    }

    return [int] ($id.Trim())
}

function ConvertFrom-JsonStringLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    try {
        return ('"' + $Value + '"') | ConvertFrom-Json
    }
    catch {
        return $Value
    }
}

function Get-UploadToken {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory = $true)]
        [string] $Repo
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "https://github.com/$Repo")
    $request.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent) | Out-Null

    $result = Invoke-HttpRequest -Client $Client -Request $request -ExpectedStatusCodes @(200) -Step 'Fetching repository page'
    $match = [regex]::Match($result.Body, '"uploadToken":"([^"]+)"')
    if (-not $match.Success) {
        throw "uploadToken not found on https://github.com/$Repo. Check write access and SSO authorization."
    }

    return ConvertFrom-JsonStringLiteral $match.Groups[1].Value
}

function ConvertTo-StringMap {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object
    )

    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = [string] $property.Value
    }
    return $map
}

function Request-UploadPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory = $true)]
        [string] $Repo,

        [Parameter(Mandatory = $true)]
        [string] $UploadToken,

        [Parameter(Mandatory = $true)]
        [int] $RepositoryId,

        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo] $FileInfo,

        [Parameter(Mandatory = $true)]
        [string] $ContentType
    )

    $form = [System.Net.Http.MultipartFormDataContent]::new()
    Add-StringFormField $form 'name' $FileInfo.Name
    Add-StringFormField $form 'size' ([string] $FileInfo.Length)
    Add-StringFormField $form 'content_type' $ContentType
    Add-StringFormField $form 'authenticity_token' $UploadToken
    Add-StringFormField $form 'repository_id' ([string] $RepositoryId)

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://github.com/upload/policies/assets')
    Add-GitHubUploadHeaders $request $Repo
    $request.Content = $form

    try {
        $result = Invoke-HttpRequest -Client $Client -Request $request -ExpectedStatusCodes @(201) -Step 'Requesting upload policy'
        $policy = $result.Body | ConvertFrom-Json
    }
    finally {
        $form.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($policy.upload_url)) {
        throw 'Upload policy response did not include upload_url.'
    }
    if ($null -eq $policy.asset -or [string]::IsNullOrWhiteSpace([string] $policy.asset.id)) {
        throw 'Upload policy response did not include asset.id.'
    }
    if ($null -eq $policy.form) {
        throw 'Upload policy response did not include S3 form fields.'
    }
    if ([string]::IsNullOrWhiteSpace($policy.asset_upload_authenticity_token)) {
        throw 'Upload policy response did not include asset_upload_authenticity_token.'
    }

    return $policy
}

function Upload-ToS3 {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Policy,

        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo] $FileInfo,

        [Parameter(Mandatory = $true)]
        [string] $ContentType
    )

    $formFields = ConvertTo-StringMap $Policy.form
    $form = [System.Net.Http.MultipartFormDataContent]::new()
    $fileStream = $null
    $client = $null

    $knownFieldOrder = @(
        'key',
        'acl',
        'policy',
        'X-Amz-Algorithm',
        'X-Amz-Credential',
        'X-Amz-Date',
        'X-Amz-Signature',
        'Content-Type',
        'Cache-Control',
        'x-amz-meta-Surrogate-Control'
    )

    foreach ($fieldName in $knownFieldOrder) {
        if ($formFields.ContainsKey($fieldName)) {
            Add-StringFormField $form $fieldName $formFields[$fieldName]
        }
    }

    foreach ($fieldName in ($formFields.Keys | Where-Object { $_ -notin $knownFieldOrder } | Sort-Object)) {
        Add-StringFormField $form $fieldName $formFields[$fieldName]
    }

    try {
        $fileStream = [System.IO.File]::OpenRead($FileInfo.FullName)
        $fileContent = [System.Net.Http.StreamContent]::new($fileStream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
        $form.Add($fileContent, 'file', $FileInfo.Name)

        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(120)

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, [string] $Policy.upload_url)
        $request.Headers.TryAddWithoutValidation('Origin', 'https://github.com') | Out-Null
        $request.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent) | Out-Null
        $request.Content = $form

        Invoke-HttpRequest -Client $client -Request $request -ExpectedStatusCodes @(200, 201, 204) -Step 'Uploading file to S3' | Out-Null
    }
    finally {
        if ($null -ne $client) {
            $client.Dispose()
        }
        $form.Dispose()
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
}

function Complete-Upload {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory = $true)]
        [string] $Repo,

        [Parameter(Mandatory = $true)]
        [object] $Policy
    )

    $form = [System.Net.Http.MultipartFormDataContent]::new()
    Add-StringFormField $form 'authenticity_token' ([string] $Policy.asset_upload_authenticity_token)

    $assetId = [int] $Policy.asset.id
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, "https://github.com/upload/assets/$assetId")
    Add-GitHubUploadHeaders $request $Repo
    $request.Content = $form

    try {
        $result = Invoke-HttpRequest -Client $Client -Request $request -ExpectedStatusCodes @(200) -Step 'Finalizing upload'
        $asset = $result.Body | ConvertFrom-Json
    }
    finally {
        $form.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($asset.href)) {
        throw 'Finalize response did not include href.'
    }

    $name = [string] $asset.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string] $Policy.asset.name
    }

    $assetContentTypeProperty = $asset.PSObject.Properties['content_type']
    $contentType = if ($null -eq $assetContentTypeProperty) { '' } else { [string] $assetContentTypeProperty.Value }
    if ([string]::IsNullOrWhiteSpace($contentType)) {
        $policyContentTypeProperty = $Policy.asset.PSObject.Properties['content_type']
        $contentType = if ($null -eq $policyContentTypeProperty) { '' } else { [string] $policyContentTypeProperty.Value }
    }

    $markdown = if ($contentType.StartsWith('video/', [StringComparison]::OrdinalIgnoreCase)) {
        [string] $asset.href
    }
    else {
        "![${name}]($($asset.href))"
    }

    return [pscustomobject] @{
        Url = [string] $asset.href
        Name = $name
        Markdown = $markdown
    }
}

function Upload-GitHubUserAttachment {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory = $true)]
        [string] $Repo,

        [Parameter(Mandatory = $true)]
        [int] $RepositoryId,

        [Parameter(Mandatory = $true)]
        [string] $ImagePath
    )

    $resolvedPath = Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop
    $fileInfo = Get-Item -LiteralPath $resolvedPath.ProviderPath
    if ($fileInfo.PSIsContainer) {
        throw "$ImagePath is a directory, expected an image file."
    }

    $contentType = Get-ContentType $fileInfo.FullName
    $uploadToken = Get-UploadToken -Client $Client -Repo $Repo
    $policy = Request-UploadPolicy -Client $Client -Repo $Repo -UploadToken $uploadToken -RepositoryId $RepositoryId -FileInfo $fileInfo -ContentType $contentType
    Upload-ToS3 -Policy $policy -FileInfo $fileInfo -ContentType $contentType
    return Complete-Upload -Client $Client -Repo $Repo -Policy $policy
}

$session = Resolve-Session
if ([string]::IsNullOrWhiteSpace($session)) {
    [Console]::Error.WriteLine("No GitHub web session configured. Run 'gh-upload-image configure' once, or set GH_USER_SESSION for this process.")
    exit 2
}

$repositoryId = Get-RepositoryId -Repo $Repo
$client = New-GitHubUploadClient -Session $session
$hadError = $false

try {
    foreach ($imagePath in $Path) {
        try {
            $result = Upload-GitHubUserAttachment -Client $client -Repo $Repo -RepositoryId $repositoryId -ImagePath $imagePath
            $result.Markdown
        }
        catch {
            $hadError = $true
            [Console]::Error.WriteLine("Failed to upload '$imagePath': $($_.Exception.Message)")
        }
    }
}
finally {
    $client.Dispose()
}

if ($hadError) {
    exit 1
}
