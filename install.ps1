# EmberStorm installer for Windows.
#
# Double-click EmberStorm-Setup.cmd, or from PowerShell:
#
#   irm https://raw.githubusercontent.com/GabrielHollberg/emberstorm/main/install.ps1 | iex
#
# It is written for somebody who has never opened a terminal. That means it
# installs Docker Desktop itself rather than sending them to a website, starts
# it rather than telling them to, and leaves a Start Menu shortcut rather than
# an address to remember. Every question it cannot answer becomes an
# instruction, not an error code.
#
#   -Launch        start an existing install and open it (what the shortcut runs)
#   -Uninstall     remove EmberStorm, keeping the media library
#   -Https         real https for a soundstorm.dev name (the default already)
#   -NoHttps       plain http only
#   -Tailscale     also reach it away from home, over a tailnet
#   -NoTailscale   stop doing that
#   -Remote        reach it from anywhere over the internet (off by default)
#   -NoRemote      keep it to the home network
#   -NoShortcuts   skip the Start Menu, Desktop and startup shortcuts
#   -NoAutoStart   install, but do not start with Windows
#   -Library PATH  keep the media library somewhere else - an external drive
#   -ChooseLibrary ask, in a window, where the library should go (what the
#                  "Move EmberStorm library" shortcut runs)
#   -Console       show progress in this console instead of a window
#
# Updating is the same as installing: run it again. It pulls newer images and
# restarts, and leaves everything else alone. -Https and -NoHttps work on an
# existing install for the same reason - they only change one line of .env.
#
# The double-dash spellings (--https) bind too, which is what somebody arriving
# from the Linux instructions will type.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Launch,
    [switch]$Uninstall,
    [switch]$Https,
    # No alias here, unlike -NoTailscale below: PowerShell already matches
    # --tailscale to -Tailscale case-insensitively, and declaring an alias
    # that differs only in case is an outright error rather than a no-op.
    [switch]$Tailscale,
    [Alias('no-tailscale')][switch]$NoTailscale,
    # The key itself, for anybody scripting this. Left out, -Tailscale asks.
    [Alias('auth-key')][string]$AuthKey,
    # The hyphenated aliases are load-bearing, not decoration. PowerShell treats
    # a leading -- as a single dash, so --https binds to -Https on its own - but
    # --no-https becomes -no-https, and a parameter *name* cannot contain a
    # hyphen. Without the alias it bound to nothing and was ignored in silence:
    # the installer reported success and left the install on http.
    [Alias('no-https')][switch]$NoHttps,
    # Putting the server on the internet, off by default. Same hyphenated-alias
    # rule as -NoHttps above.
    [switch]$Remote,
    [Alias('no-remote')][switch]$NoRemote,
    [Alias('no-shortcuts')][switch]$NoShortcuts,
    [Alias('no-auto-start')][switch]$NoAutoStart,
    [Alias('no-browser')][switch]$NoBrowser,
    # No alias: --library already binds to -Library, and an alias differing
    # only in case is an error rather than a no-op.
    [string]$Library,
    [Alias('choose-library')][switch]$ChooseLibrary,
    # Moving to another computer: -Export packs this install into a
    # EmberStorm-move folder in the path given (-Move asks where, for the
    # Start menu shortcut); -Import installs from one. -NoLibrary leaves the
    # media out of an export, for somebody copying it themselves.
    [string]$Export,
    [switch]$Move,
    [string]$Import,
    [Alias('no-library')][switch]$NoLibrary,
    [switch]$Console
)

# A Tailscale key handed over by a relaunch comes in the environment, never
# the command line, which other accounts on the machine can read (the twelfth
# security pass).
if (-not $AuthKey -and $env:SOUNDSTORM_TS_KEY) { $AuthKey = $env:SOUNDSTORM_TS_KEY }
Remove-Item Env:SOUNDSTORM_TS_KEY -ErrorAction SilentlyContinue

if ($Https -and $NoHttps) {
    Write-Host "  -Https and -NoHttps cannot both be given." -ForegroundColor Red
    exit 1
}
if ($Tailscale -and $NoTailscale) {
    Write-Host "  -Tailscale and -NoTailscale cannot both be given." -ForegroundColor Red
    exit 1
}
if ($Remote -and $NoRemote) {
    Write-Host "  -Remote and -NoRemote cannot both be given." -ForegroundColor Red
    exit 1
}

# Older .NET defaults this to SSL 3.0 and TLS 1.0, and GitHub has required TLS
# 1.2 since 2018 - so on an otherwise healthy machine every download below
# fails, with an error that blames the connection rather than the protocol.
#
# Only when it has been pinned to something. Left at SystemDefault, Windows
# picks the best protocol it has, which is better than anything named here -
# forcing Tls12 in that case would switch TLS 1.3 off on Windows 11.
try {
    if ([Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault) {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
} catch {
    # A .NET too old to know SystemDefault, or too new to expose the enum.
}

$ErrorActionPreference = 'Stop'

# Started again after a restart (Register-Resume): the settings that run had -
# its install folder, a repository or branch given - come back from the file
# it left, before anything reads them (a review, 2026-10-09: an install in a
# folder of its own carried on in the default one after a restart).
$script:ResumeCopy = Join-Path $env:LOCALAPPDATA 'EmberStorm\soundstorm-install.ps1'
$script:ResumeFile = Join-Path $env:LOCALAPPDATA 'EmberStorm\resume.env'
$resumeFresh = $false
try { $resumeFresh = ((Get-Date) - (Get-Item -LiteralPath $script:ResumeFile -ErrorAction Stop).LastWriteTime).TotalDays -lt 3 } catch { }
if (-not $Launch -and $resumeFresh) {
    try {
        foreach ($line in [IO.File]::ReadAllLines($script:ResumeFile)) {
            if ($line -match '^(SOUNDSTORM_(DIR|PORT)|EMBERSTORM_(RESUMES|ASKED|LAN|LIBRARY|DOCKER_OURS|DOCKER_C))=(.*)$') {
                [Environment]::SetEnvironmentVariable($Matches[1], $Matches[4], 'Process')
            }
        }
    } catch { }
    Remove-Item -LiteralPath $script:ResumeFile -Force -ErrorAction SilentlyContinue
}
# Whichever process carries on after a restart - the resumed copy, the newer
# script it hands over to, or the window it relaunches - takes the library
# chosen before it: the environment reaches them all, $Library does not (the
# blind review: media landed on a small C: after a restart).
if ($env:EMBERSTORM_LIBRARY -and -not $Library) { $Library = $env:EMBERSTORM_LIBRARY }

$Repo       = if ($env:SOUNDSTORM_REPO) { $env:SOUNDSTORM_REPO } else { 'GabrielHollberg/emberstorm' }
$Branch     = if ($env:SOUNDSTORM_BRANCH) { $env:SOUNDSTORM_BRANCH } else { 'main' }
$RawBase    = "https://raw.githubusercontent.com/$Repo/$Branch"

# raw.githubusercontent.com caches a branch URL for five minutes, and ignores a
# query string when it does - checked: a never-seen random query came back
# "X-Cache: HIT". So a fix pushed a minute ago reached a laptop as the version
# before it, and the setup showed the exact error the push had fixed. A commit
# URL cannot be stale, so the branch is resolved to its newest commit first,
# through the API (whose answer is fresh), and the branch URL is only the
# fallback when the API cannot be asked. Not on -Launch: opening the app must
# not wait on GitHub.
if (-not $Launch -and -not $env:SOUNDSTORM_COMPOSE_URL -and -not $env:SOUNDSTORM_SCRIPT_URL) {
    try {
        $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/commits/$Branch" `
            -Headers @{ 'User-Agent' = 'soundstorm-installer'; 'Accept' = 'application/vnd.github+json' } `
            -TimeoutSec 15 -UseBasicParsing
        if ("$($commit.sha)" -match '^[0-9a-f]{40}$') {
            $RawBase = "https://raw.githubusercontent.com/$Repo/$($commit.sha)"
        }
    } catch {
        # Rate-limited or offline: the branch URL, at worst five minutes old.
    }
}
$ComposeUrl = if ($env:SOUNDSTORM_COMPOSE_URL) { $env:SOUNDSTORM_COMPOSE_URL } else { "$RawBase/docker-compose.yml" }
$ScriptUrl  = if ($env:SOUNDSTORM_SCRIPT_URL) { $env:SOUNDSTORM_SCRIPT_URL } else { "$RawBase/install.ps1" }
# Only ever over https: what is downloaded here runs.
if ($ComposeUrl -notmatch '^https://') { $ComposeUrl = "$RawBase/docker-compose.yml" }
if ($ScriptUrl -notmatch '^https://') { $ScriptUrl = "$RawBase/install.ps1" }

# Under the user's own folder rather than Program Files: the media library
# lives beside the compose file, and it has to be somewhere they can drop a
# hard drive of music into without a permission prompt.
# The product was called SoundStorm before EmberStorm (2026-10-07): an install
# made then lives in a folder of that name, and is found there, so updating it
# carries on in place.
# Run as the copy saved in an install folder - the shortcuts, the uninstall
# entry - that folder is the install, wherever it is: an install made with
# SOUNDSTORM_DIR elsewhere was looked for in the default folder, and its icon,
# update and uninstall all failed (a review, 2026-10-09). Set in the
# environment, so the newer copy this may hand over to keeps it.
if (-not $env:SOUNDSTORM_DIR -and $PSCommandPath -and [IO.Path]::GetFileName($PSCommandPath) -eq 'soundstorm.ps1' -and
    (Test-Path (Join-Path $PSScriptRoot 'docker-compose.yml'))) {
    $env:SOUNDSTORM_DIR = $PSScriptRoot
}
$Dir       = if ($env:SOUNDSTORM_DIR) { $env:SOUNDSTORM_DIR }
             elseif (Test-Path (Join-Path $env:USERPROFILE 'SoundStorm\docker-compose.yml')) { Join-Path $env:USERPROFILE 'SoundStorm' }
             else { Join-Path $env:USERPROFILE 'EmberStorm' }
$FirstPort = if ($env:SOUNDSTORM_PORT) { [int]$env:SOUNDSTORM_PORT } else { 8099 }

# Updating runs the newest installer, not the one saved last time.
#
# "Update EmberStorm" runs the copy of this script saved beside the install,
# and the setup file runs whatever it just downloaded - so each update used to
# run the *previous* version's logic, and a fix to the installer itself only
# took effect on the update after the one that fetched it. So a saved or
# downloaded copy fetches the newest script and, when it differs, hands over to
# it with the same arguments. Only those two copies: a checkout being tested
# runs as it is. SOUNDSTORM_FRESH stops the new copy doing the same again.
$selfName = if ($PSCommandPath) { [IO.Path]::GetFileName($PSCommandPath) } else { '' }
if (-not $Launch -and $env:SOUNDSTORM_FRESH -ne '1' -and
    ($selfName -eq 'soundstorm.ps1' -or $selfName -eq 'soundstorm-install.ps1')) {
    $fresh = Join-Path $env:TEMP "soundstorm-fresh-$PID.ps1"
    $handOver = $false
    try {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $fresh -UseBasicParsing -TimeoutSec 30
        $newText = [IO.File]::ReadAllText($fresh)
        $oldText = [IO.File]::ReadAllText($PSCommandPath)
        $handOver = ($newText -ne $oldText -and $newText -match 'SOUNDSTORM_FRESH')
    } catch {
        # Offline, or GitHub unreachable: carry on with this copy, which is
        # what would have happened before.
    }
    if ($handOver) {
        # Outside the try above on purpose: a failure inside the new copy must
        # end here, not fall back to running this old one as well.
        $env:SOUNDSTORM_FRESH = '1'
        $code = 1
        try {
            & $fresh @PSBoundParameters
            $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        } catch {
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
        }
        exit $code
    }
    Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
}

# --- the setup window -----------------------------------------------------------
#
# The people this is for are put off by a console, and the console used to be
# the whole experience: twenty minutes of a black window with text scrolling
# in it. So an interactive setup relaunches itself with its console hidden and
# shows a window instead - the four steps ticking off, what it is doing now, a
# progress bar, what to click in the windows Docker opens, and at the end the
# setup code and an Open EmberStorm button. The console output is still all
# there, under "Show details", and in a log file for whoever is helping.
#
# The window runs on the same thread as the setup, pumped from every place the
# script waits (Write-Host, Start-Sleep, waiting on a process, each line docker
# prints). That keeps every dialog - the folder picker, the network question -
# owned by one thread, which Windows Forms requires, and changes none of the
# setup's own logic. The cost is a window that can stop repainting for the few
# seconds of a docker call that prints nothing, which is far better than the
# alternatives of a second thread or a compiled helper that Smart App Control
# would block.
#
# ASCII only, like the rest of this file: the tick and arrow characters are
# made from their code points at run time.

$script:Gui = $null
$script:SetupLog = Join-Path $env:TEMP 'EmberStorm-setup.log'

# Update-Gui lets the window repaint and answer clicks. A no-op without one.

# Write-Host is wrapped, not replaced: everything this script prints still goes
# to the console when there is one, and to the log file always - and, with the
# window up, into its details box instead of a console nobody can see.
function Write-Host {
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)] $Object,
        [ConsoleColor] $ForegroundColor,
        [ConsoleColor] $BackgroundColor,
        [switch] $NoNewline,
        $Separator = ' '
    )
    $text = if ($null -eq $Object) { '' } else { (@($Object) | ForEach-Object { "$_" }) -join $Separator }
    $end = if ($NoNewline) { '' } else { "`r`n" }
    try { [IO.File]::AppendAllText($script:SetupLog, $text + $end) } catch { }
    if ($script:Gui) {
        Add-GuiDetail ($text + $end)
        return
    }
    $pass = @{ Object = $text; NoNewline = $NoNewline }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $pass.ForegroundColor = $ForegroundColor }
    if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $pass.BackgroundColor = $BackgroundColor }
    Microsoft.PowerShell.Utility\Write-Host @pass
}

# Start-Sleep keeps the window alive while it waits. Every wait in this script
# is a sleep in a loop, so this one wrapper covers them all.
function Start-Sleep {
    param([Parameter(Position = 0)][double]$Seconds = 0, [int]$Milliseconds = 0)
    $total = [int]($Seconds * 1000) + $Milliseconds
    if (-not $script:Gui) {
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $total
        return
    }
    $until = (Get-Date).AddMilliseconds($total)
    while ((Get-Date) -lt $until) {
        Update-Gui
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 50
    }
}

# Wait-ProcessPumped waits for a process to exit, keeping the window alive.
# Returns $false if TimeoutSeconds passed first (0 waits for ever).
#
# Reading .Handle is not a no-op and is not optional. Start-Process -PassThru
# hands back a Process with no cached handle, and without one WaitForExit never
# observes the exit - it times out on a program that finished in a second.
function Wait-ProcessPumped($Process, [int]$TimeoutSeconds = 0) {
    $null = $Process.Handle
    $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { [DateTime]::MaxValue }
    while (-not $Process.WaitForExit(100)) {
        Update-Gui
        if ((Get-Date) -gt $deadline) { return $false }
    }
    return $true
}

# Read-Text asks for one line of text: in a box with the window up, since a
# hidden console cannot be typed into, and on the console otherwise.
function Read-Text([string]$Prompt, [string]$Title = 'EmberStorm Setup') {
    if ($script:Gui) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, '')
    }
    return (Read-Host "  $Prompt")
}

function New-GuiFont([float]$Size, [System.Drawing.FontStyle]$Style = 'Regular', [string]$Family = 'Segoe UI') {
    return (New-Object System.Drawing.Font($Family, $Size, $Style))
}

# The window's colours: the app's own - black, light text, its blue - so the
# setup looks like what it installs (2026-10-09: it was a plain white box).
# Only once System.Drawing is there: a run that never shows a window (the
# desktop icon, the console) must not fail on a type it does not need.
try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { }
$script:Ui = @{}
try { $script:Ui = @{
    Bg     = [System.Drawing.Color]::FromArgb(14, 14, 18)
    Panel  = [System.Drawing.Color]::FromArgb(28, 28, 36)
    Text   = [System.Drawing.Color]::FromArgb(235, 235, 245)
    Dim    = [System.Drawing.Color]::FromArgb(150, 150, 165)
    Faint  = [System.Drawing.Color]::FromArgb(95, 95, 110)
    Accent = [System.Drawing.Color]::FromArgb(106, 168, 255)
    Good   = [System.Drawing.Color]::FromArgb(76, 195, 138)
    Warn   = [System.Drawing.Color]::FromArgb(240, 168, 72)
    Bad    = [System.Drawing.Color]::FromArgb(255, 112, 112)
} } catch { }

# Draw-Cloud paints the EmberStorm cloud and its bolt - the logo's own shapes,
# as scripts/make-icons.py draws them - Height pixels tall at X, Y.
function Draw-Cloud($Graphics, [float]$X, [float]$Y, [float]$Height, $Color) {
    $k = $Height / 125.0
    $ox = $X - 176.5 * $k
    $oy = $Y - 177.0 * $k
    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush $Color
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse([float]($ox + (234.0 - 43.5) * $k), [float]($oy + (220.5 - 43.5) * $k), [float](87.0 * $k), [float](87.0 * $k))
    $path.AddEllipse([float]($ox + (283.0 - 23.7) * $k), [float]($oy + (212.7 - 23.7) * $k), [float](47.4 * $k), [float](47.4 * $k))
    $r = 42.0 * $k
    $bx = $ox + 176.5 * $k; $by = $oy + 207.0 * $k; $bw = 148.0 * $k; $bh = 42.0 * $k
    $path.AddArc([float]$bx, [float]$by, [float]$r, [float]$r, 90, 180)
    $path.AddArc([float]($bx + $bw - $r), [float]$by, [float]$r, [float]$r, 270, 180)
    $path.CloseFigure()
    $old = $Graphics.Clip
    $Graphics.SetClip((New-Object System.Drawing.RectangleF ([float]$X - 1), ([float]$Y - 1), ([float](150 * $k) + 2), ([float]($oy + 249.0 * $k - $Y + 1))))
    $Graphics.FillPath($brush, $path)
    $Graphics.Clip = $old
    $points = @((243, 240), (271, 240), (260, 261), (278, 261), (238, 302), (251, 273), (231, 273)) |
        ForEach-Object { New-Object System.Drawing.PointF ([float]($ox + $_[0] * $k)), ([float]($oy + $_[1] * $k)) }
    $Graphics.FillPolygon($brush, [System.Drawing.PointF[]]$points)
    $brush.Dispose(); $path.Dispose()
}

# Set-DarkTheme gives a window of the setup's own (the library question, the
# always-on one) the main window's colours.
function Set-DarkTheme($Control) {
    $Control.BackColor = $script:Ui.Bg
    $Control.ForeColor = $script:Ui.Text
    foreach ($c in $Control.Controls) {
        if ($c -is [System.Windows.Forms.Button]) {
            $c.FlatStyle = 'Flat'
            $c.FlatAppearance.BorderSize = 0
            $c.BackColor = $script:Ui.Panel
            $c.ForeColor = $script:Ui.Text
        } elseif ($c -is [System.Windows.Forms.TextBox]) {
            $c.BackColor = $script:Ui.Panel
            $c.ForeColor = $script:Ui.Text
            $c.BorderStyle = 'FixedSingle'
        } elseif ($c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.Label]) {
            if ($c.ForeColor -eq [System.Drawing.Color]::DimGray -or $c.ForeColor -eq [System.Drawing.Color]::Gray) { $c.ForeColor = $script:Ui.Dim }
            elseif ($c.ForeColor -eq [System.Drawing.Color]::Firebrick) { $c.ForeColor = $script:Ui.Bad }
            else { $c.ForeColor = $script:Ui.Text }
            $c.BackColor = $script:Ui.Bg
        }
    }
}

# Set-PrimaryButton draws a button in the app's blue: the one to press.
function Set-PrimaryButton($Button) {
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $script:Ui.Accent
    $Button.ForeColor = [System.Drawing.Color]::FromArgb(10, 10, 14)
    $Button.Font = New-GuiFont 10 'Bold'
}

# New-SetupWindow builds the window and shows it, without waiting on it.
#
# WPF, not Windows Forms (2026-10-09, the owner: the window "looks old, plain
# text"): a borderless window with rounded corners and a title bar of its own,
# the cloud drawn from the logo's own shapes, steps with markers, a bar with a
# gradient and a light running along it, cards for what to read, and the
# questions as pages in this same window - so, going to plan, a person sees
# this one window and Windows' own permission prompts, nothing else. It sizes
# itself to what it shows. WPF is part of Windows (.NET Framework): nothing is
# installed or compiled for it. The functions below are the same ones the rest
# of the setup always called.
function New-SetupWindow([string]$Heading, [string]$Subheading, [string[]]$StepNames) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="EmberStorm Setup" Width="680" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#EBEBF5"/>
      <Setter Property="Background" Value="#262631"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Margin" Value="10,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="9" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.7"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="#0A0A10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#7DB4FF" Offset="0"/>
            <GradientStop Color="#5E9BFF" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Foreground" Value="#9696A5"/>
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="7" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#262631"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="14" CornerRadius="16" BorderBrush="#2A2A36" BorderThickness="1">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#16161E" Offset="0"/>
        <GradientStop Color="#0D0D12" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect>
      <DropShadowEffect BlurRadius="22" ShadowDepth="0" Opacity="0.55" Color="Black"/>
    </Border.Effect>
    <StackPanel Margin="30,14,30,24">
      <Grid x:Name="Header" Background="Transparent" Margin="0,0,0,18">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Viewbox x:Name="Logo" Height="26" Margin="0,2,10,0">
            <Canvas Width="148" Height="125">
              <Canvas>
                <Canvas.Clip><RectangleGeometry Rect="0,0,148,72"/></Canvas.Clip>
                <Ellipse Canvas.Left="14" Canvas.Top="0" Width="87" Height="87" Fill="White"/>
                <Ellipse Canvas.Left="82.8" Canvas.Top="12" Width="47.4" Height="47.4" Fill="White"/>
                <Rectangle Canvas.Left="0" Canvas.Top="30" Width="148" Height="42" RadiusX="21" RadiusY="21" Fill="White"/>
              </Canvas>
              <Polygon Points="66.5,63 94.5,63 83.5,84 101.5,84 61.5,125 74.5,96 54.5,96" Fill="White"/>
            </Canvas>
          </Viewbox>
          <TextBlock Text="EmberStorm" Foreground="#EBEBF5" FontSize="16" FontWeight="Bold" FontStyle="Italic" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="MinButton" Style="{StaticResource Chrome}" ToolTip="Minimize" AutomationProperties.Name="Minimize">
            <Rectangle Width="11" Height="1.4" Fill="#9696A5"/>
          </Button>
          <Button x:Name="XButton" Style="{StaticResource Chrome}" ToolTip="Close" AutomationProperties.Name="Close">
            <Path Data="M0,0 L10,10 M10,0 L0,10" Stroke="#9696A5" StrokeThickness="1.4"/>
          </Button>
        </StackPanel>
      </Grid>
      <TextBlock x:Name="Title" Foreground="#F2F2FA" FontSize="26" FontWeight="SemiBold" TextWrapping="Wrap" FontFamily="Segoe UI Variable Display, Segoe UI"/>
      <TextBlock x:Name="Sub" Foreground="#9696A5" FontSize="14" TextWrapping="Wrap" Margin="0,6,0,20" LineHeight="20"/>
      <StackPanel x:Name="Steps" Margin="0,0,0,18"/>
      <StackPanel x:Name="ProgressPanel" Margin="0,2,0,4">
        <Grid Margin="0,0,0,10">
          <TextBlock x:Name="Status" Foreground="#EBEBF5" TextWrapping="Wrap" Margin="0,0,70,0" LineHeight="20"/>
          <TextBlock x:Name="Percent" Foreground="#9696A5" HorizontalAlignment="Right" VerticalAlignment="Bottom" FontWeight="SemiBold"/>
        </Grid>
        <Border x:Name="Track" Height="8" CornerRadius="4" Background="#24242E" ClipToBounds="True">
          <Grid HorizontalAlignment="Left">
            <Border x:Name="Fill" CornerRadius="4" Width="0">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#5E9BFF" Offset="0"/>
                  <GradientStop Color="#9A86FF" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
            <Border x:Name="Shine" Width="90" CornerRadius="4" HorizontalAlignment="Left">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#00FFFFFF" Offset="0"/>
                  <GradientStop Color="#66FFFFFF" Offset="0.5"/>
                  <GradientStop Color="#00FFFFFF" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.RenderTransform><TranslateTransform x:Name="ShineMove" X="0"/></Border.RenderTransform>
            </Border>
          </Grid>
        </Border>
      </StackPanel>
      <Border x:Name="Card" CornerRadius="12" Padding="18,14" Margin="0,16,0,0" BorderThickness="1" Visibility="Collapsed">
        <ScrollViewer MaxHeight="380" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="CardBody"/>
        </ScrollViewer>
      </Border>
      <ScrollViewer x:Name="PageScroll" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Margin="0,4,0,0">
        <StackPanel x:Name="Page"/>
      </ScrollViewer>
      <TextBox x:Name="Details" Visibility="Collapsed" Height="200" Margin="0,16,0,0" IsReadOnly="True"
               Background="#0A0A0E" Foreground="#C8C8D2" BorderBrush="#2A2A36" Padding="8"
               FontFamily="Cascadia Mono, Consolas" FontSize="12" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
      <Grid Margin="0,22,0,0">
        <TextBlock VerticalAlignment="Center">
          <Hyperlink x:Name="Toggle" Foreground="#7F7F90" TextDecorations="{x:Null}">Show details</Hyperlink>
        </TextBlock>
        <StackPanel x:Name="Buttons" Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="ActButton" Style="{StaticResource Primary}" Visibility="Collapsed"/>
          <Button x:Name="OpenButton" Style="{StaticResource Primary}" Visibility="Collapsed" Content="Open EmberStorm"/>
          <Button x:Name="CloseButton" Style="{StaticResource Btn}" Content="Cancel" IsCancel="True"/>
        </StackPanel>
        <StackPanel x:Name="PageButtons" Orientation="Horizontal" HorizontalAlignment="Right" Visibility="Collapsed"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $g = @{
        Window   = $window
        Running  = $true
        Closed   = $false
        OpenUrl  = ''
        ShowLog  = $false
        Steps    = @()
        Current  = 0
        Expanded = $false
        Progress = 0.0
        Lo       = 0.0
        Hi       = 0.02
        Phase    = 0.0
        Tick     = [DateTime]::Now
        Choice   = $null
        StepRows = @()
    }
    foreach ($name in 'Header', 'Logo', 'Title', 'Sub', 'Steps', 'ProgressPanel', 'Status', 'Percent', 'Track', 'Fill', 'Shine',
            'ShineMove', 'Card', 'CardBody', 'Page', 'PageScroll', 'Details', 'Toggle', 'Buttons', 'ActButton', 'OpenButton', 'CloseButton',
            'PageButtons', 'MinButton', 'XButton') {
        $g[$name] = $window.FindName($name)
    }
    $g.Title.Text = $Heading
    $g.Sub.Text = $Subheading
    foreach ($stepName in $StepNames) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = '0,4,0,4'
        $mark = New-Object System.Windows.Controls.Border
        $mark.Width = 22; $mark.Height = 22; $mark.CornerRadius = 11; $mark.Margin = '0,0,12,0'
        $glyph = New-Object System.Windows.Controls.TextBlock
        $glyph.HorizontalAlignment = 'Center'; $glyph.VerticalAlignment = 'Center'
        $glyph.FontFamily = 'Segoe UI Symbol'; $glyph.FontSize = 12; $glyph.FontWeight = 'Bold'
        $mark.Child = $glyph
        $label = New-Object System.Windows.Controls.TextBlock
        $label.VerticalAlignment = 'Center'
        $label.Text = $stepName
        $label.Tag = $stepName
        [void]$row.Children.Add($mark)
        [void]$row.Children.Add($label)
        [void]$g.Steps.Children.Add($row)
        $g.StepRows += , @{ Mark = $mark; Glyph = $glyph; Label = $label }
    }

    # A small screen (a laptop at 150%, a TV as the monitor): the window never
    # taller than it, the card and pages scrolling inside, and kept on it as
    # it grows (a review: its buttons went below the taskbar).
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.MaxHeight = $area.Height - 16
    $room = [Math]::Max(160, $area.Height - 430)
    $window.FindName('Card').Child.MaxHeight = [Math]::Min(380, $room)
    $g.PageScroll.MaxHeight = [Math]::Max(220, $area.Height - 250)
    $window.Add_SizeChanged({
        $win = $script:Gui.Window
        $a = [System.Windows.SystemParameters]::WorkArea
        if ($win.Top + $win.ActualHeight -gt $a.Bottom) { $win.Top = [Math]::Max($a.Top, $a.Bottom - $win.ActualHeight) }
        if ($win.Top -lt $a.Top) { $win.Top = $a.Top }
    })

    $g.Header.Add_MouseLeftButtonDown({ try { $script:Gui.Window.DragMove() } catch { } })
    $g.MinButton.Add_Click({ $script:Gui.Window.WindowState = 'Minimized' })
    $g.XButton.Add_Click({ $script:Gui.Window.Close() })
    $g.CloseButton.Add_Click({ $script:Gui.Window.Close() })
    $g.OpenButton.Add_Click({
        if ($script:Gui.ShowLog) {
            Protect-SetupLog
            # Explorer with the file selected: the thing to send, found.
            Start-Process explorer.exe -ArgumentList "/select,`"$script:SetupLog`""
        } elseif ($script:Gui.OpenUrl) {
            Start-Process $script:Gui.OpenUrl
        }
    })
    $g.Toggle.Add_Click({
        $w = $script:Gui
        $w.Expanded = -not $w.Expanded
        $w.Details.Visibility = if ($w.Expanded) { 'Visible' } else { 'Collapsed' }
        $w.Toggle.Inlines.Clear()
        $w.Toggle.Inlines.Add($(if ($w.Expanded) { 'Hide details' } else { 'Show details' }))
        if ($w.Expanded) { $w.Details.ScrollToEnd() }
    })

    # Closing while it works asks first, and means it: the setup stops. What
    # was downloaded is kept, so running it again carries on from there.
    $window.Add_Closing({
        param($sender, $e)
        if ($script:Gui.Running) {
            $answer = [System.Windows.MessageBox]::Show($sender,
                $(if ($script:CloseQuestion) { $script:CloseQuestion } else { "EmberStorm is still being set up.`r`n`r`nStop now? Anything already downloaded is kept, and running the setup again carries on from there." }),
                'EmberStorm Setup', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') {
                $e.Cancel = $true
                return
            }
            try { [IO.File]::AppendAllText($script:SetupLog, "Stopped from the window.`r`n") } catch { }
            # Ended by the setup itself at its next moment (Update-Gui), not
            # from inside the window's own event: the process left at once,
            # mid-step, with nothing tidied (a review).
            $script:Gui.StopAsked = $true
            $script:Gui.Running = $false
        }
        $script:Gui.Closed = $true
    })

    # The bar: each step's share filled from what it reports, creeping on
    # where nothing can be measured, a light running along it.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(33)
    $timer.Add_Tick({
        $w = $script:Gui
        if (-not $w) { return }
        $now = [DateTime]::Now
        $dt = ($now - $w.Tick).TotalSeconds
        $w.Tick = $now
        if ($w.Running) {
            $target = $w.Lo + ($w.Hi - $w.Lo) * 0.97
            if ($w.Progress -lt $target) { $w.Progress += ($target - $w.Progress) * [Math]::Min(1.0, $dt / 180.0) }
            $w.Phase += $dt / 1.8
            $w.Percent.Text = "$([int]([Math]::Floor($w.Progress * 100)))%"
        }
        $width = $w.Track.ActualWidth * [Math]::Max(0.0, [Math]::Min(1.0, $w.Progress))
        $w.Fill.Width = $width
        $w.Shine.Visibility = if ($w.Running -and $width -gt 20) { 'Visible' } else { 'Collapsed' }
        $w.ShineMove.X = (($w.Phase % 1.0) * ($width + 90)) - 90
        $w.Shine.Clip = New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect ([Math]::Max(0, -$w.ShineMove.X)), 0, ([Math]::Max(0, $width - [Math]::Max(0, $w.ShineMove.X))), 8)
    })
    $timer.Start()
    $g.Timer = $timer

    $script:Gui = $g
    Set-GuiStepMarks
    # Shown twice, and the first is not a mistake. This process was started
    # hidden (so its console never appears), and Windows applies "hidden" to
    # the first window a process shows - which here is this one, since the
    # console belongs to another process.
    $window.Show()
    $window.Hide()
    $window.Show()
    [void]$window.Activate()
    Update-Gui
    # The taskbar's picture: the cloud, drawn from the window's own logo.
    try {
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap 64, 64, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $visual = New-Object System.Windows.Media.DrawingVisual
        $dc = $visual.RenderOpen()
        $dc.DrawRoundedRectangle((New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(14, 14, 18))), $null, (New-Object System.Windows.Rect 0, 0, 64, 64), 14, 14)
        $brush = New-Object System.Windows.Media.VisualBrush $g.Logo
        $dc.DrawRectangle($brush, $null, (New-Object System.Windows.Rect 8, 12, 48, 41))
        $dc.Close()
        $bmp.Render($visual)
        $window.Icon = $bmp
    } catch { }
}

# Update-Gui lets the window draw and answer while the setup works on: every
# wait and every line docker prints comes through here.
function Update-Gui {
    if (-not $script:Gui) { return }
    try {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null },
            $frame)
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch { }
    if ($script:Gui.StopAsked) {
        $script:Gui.StopAsked = $false
        # An update stopped before its new versions were in: the compose file
        # that names what is here goes back, or the next start would ask for
        # versions never downloaded (the blind review).
        try {
            $old = Join-Path $Dir 'docker-compose.yml.old'
            if (Test-Path -LiteralPath $old) { Move-Item -Force -LiteralPath $old (Join-Path $Dir 'docker-compose.yml') }
        } catch { }
        try { $script:Gui.Timer.Stop() } catch { }
        try { $script:Gui.Window.Close() } catch { }
        exit 1
    }
}

# Invoke-Pumped runs a piece of work on a second thread while this one keeps
# the window drawn and draggable: a command that prints nothing for a while
# (docker info as Docker starts, checking the 600MB installer's signature)
# froze the window for 20-30 seconds on the test box, and a frozen window
# reads as a broken one. Without the window it simply runs.
function Invoke-Pumped([scriptblock]$Work, [object[]]$Arguments = @()) {
    if (-not $script:Gui) { return (& $Work @Arguments) }
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($Work.ToString())
        foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        while (-not $handle.IsCompleted) {
            Update-Gui
            [Threading.Thread]::Sleep(50)
        }
        return $ps.EndInvoke($handle)
    } finally {
        $ps.Dispose()
    }
}

function New-WpfBrush([string]$Hex) {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

# Set-GuiStepMarks draws each step as done, current or still to come.
function Set-GuiStepMarks([switch]$Failed) {
    $w = $script:Gui
    for ($i = 0; $i -lt $w.StepRows.Count; $i++) {
        $row = $w.StepRows[$i]
        $n = $i + 1
        $row.Label.Text = $row.Label.Tag
        if ($n -lt $w.Current) {
            $row.Mark.Background = New-WpfBrush '#1F4A35'
            $row.Mark.BorderThickness = 0
            $row.Glyph.Text = [string][char]0x2713
            $row.Glyph.Foreground = New-WpfBrush '#4CC38A'
            $row.Label.Foreground = New-WpfBrush '#B9B9C6'
            $row.Label.FontWeight = 'Normal'
        } elseif ($n -eq $w.Current) {
            if ($Failed) {
                $row.Mark.Background = New-WpfBrush '#4A1E22'
                $row.Glyph.Text = [string][char]0x2715
                $row.Glyph.Foreground = New-WpfBrush '#FF7070'
                $row.Label.Foreground = New-WpfBrush '#FF8A8A'
            } else {
                $row.Mark.Background = New-WpfBrush '#1C2E4E'
                $row.Glyph.Text = [string][char]0x25CF
                $row.Glyph.Foreground = New-WpfBrush '#7DB4FF'
                $row.Label.Foreground = New-WpfBrush '#F2F2FA'
            }
            $row.Mark.BorderThickness = 0
            $row.Label.FontWeight = 'SemiBold'
        } else {
            $row.Mark.Background = [System.Windows.Media.Brushes]::Transparent
            $row.Mark.BorderBrush = New-WpfBrush '#3A3A48'
            $row.Mark.BorderThickness = 1.5
            $row.Glyph.Text = ''
            $row.Label.Foreground = New-WpfBrush '#8E8E9E'
            $row.Label.FontWeight = 'Normal'
        }
    }
}

# Set-GuiStep moves the window on to "Step N of M - what it is doing".
function Set-GuiStep([string]$Text) {
    if (-not $script:Gui) { return }
    $w = $script:Gui
    if ($Text -match 'Step (\d+) of \d+ - (.+)$') {
        $n = [int]$Matches[1]
        if ($n -ge 1 -and $n -le $w.StepRows.Count) {
            $w.StepRows[$n - 1].Label.Tag = $Matches[2]
            $w.Current = $n
            # Each step's share of the bar, by how long it really takes on a
            # fresh PC: getting Docker, the folder and the questions, the
            # long download, starting up.
            $shares = @{ 1 = @(0.0, 0.24); 2 = @(0.24, 0.30); 3 = @(0.30, 0.92); 4 = @(0.92, 0.99) }
            if ($shares.ContainsKey($n)) {
                $w.Lo = $shares[$n][0]
                $w.Hi = $shares[$n][1]
                if ($w.Progress -lt $w.Lo) { $w.Progress = $w.Lo }
            }
        }
    }
    # A new step is a new stage, and what the last one said to do is over.
    $w.Card.Visibility = 'Collapsed'
    $w.Status.Text = ''
    Set-GuiStepMarks
    Update-Gui
}

# Set-GuiStatus is the one line above the bar saying what is happening now.
function Set-GuiStatus([string]$Text, [string]$Kind = 'Note') {
    if (-not $script:Gui) { return }
    $script:Gui.Status.Text = $Text.Trim()
    $script:Gui.Status.Foreground = switch ($Kind) {
        'Good' { New-WpfBrush '#4CC38A' }
        'Important' { New-WpfBrush '#F0A848' }
        default { New-WpfBrush '#EBEBF5' }
    }
    Update-Gui
}

# Set-GuiStepProgress says how far through its own step the setup is, 0 to 1,
# when it can measure it; the bar never goes back.
function Set-GuiStepProgress([double]$Fraction) {
    if (-not $script:Gui) { return }
    $w = $script:Gui
    $f = [Math]::Max(0.0, [Math]::Min(1.0, $Fraction))
    $at = $w.Lo + ($w.Hi - $w.Lo) * $f
    if ($at -gt $w.Progress) { $w.Progress = $at }
}

function Add-GuiDetail([string]$Text) {
    $box = $script:Gui.Details
    $box.AppendText($Text)
    if ($script:Gui.Expanded) { $box.ScrollToEnd() }
    Update-Gui
}

# New-GuiLine is one line of a card or a page: words, with any web address a
# link to open.
function New-GuiLine([string]$Text, [double]$Size = 14, [string]$Color = '#D8D8E2', [string]$Weight = 'Normal') {
    $block = New-Object System.Windows.Controls.TextBlock
    $block.TextWrapping = 'Wrap'
    $block.FontSize = $Size
    $block.FontWeight = $Weight
    $block.Foreground = New-WpfBrush $Color
    $block.LineHeight = $Size * 1.45
    $rest = $Text
    while ($rest -match '(https?://\S+|\b(?:[a-z0-9-]+\.)+(?:com|app|dev|net)/\S*)') {
        $at = $rest.IndexOf($Matches[1])
        if ($at -gt 0) { $block.Inlines.Add($rest.Substring(0, $at)) }
        $address = $Matches[1]
        $link = New-Object System.Windows.Documents.Hyperlink
        $link.Inlines.Add($address)
        $link.Foreground = New-WpfBrush '#8DBBFF'
        $link.Tag = if ($address -match '^https?://') { $address } else { "https://$address" }
        $link.Add_Click({ param($s) try { Start-Process $s.Tag } catch { } })
        $block.Inlines.Add($link)
        $rest = $rest.Substring($at + $address.Length)
    }
    if ($rest) { $block.Inlines.Add($rest) }
    return $block
}

# Set-GuiMessage shows a callout - what to know about Docker, the setup code,
# what went wrong - as a card in the window. A line starting with "*" is the
# thing itself, an address or a code: drawn large, and selectable to copy.
function Set-GuiMessage([string]$Title, [string[]]$Lines, [string]$Color = 'Yellow') {
    if (-not $script:Gui) { return }
    $w = $script:Gui
    $look = switch ($Color) {
        'Cyan' { @('#13213A', '#25406B', '#8DBBFF') }
        'Green' { @('#11281E', '#22573D', '#5FD39C') }
        'Red' { @('#33161A', '#6A2B30', '#FF8A8A') }
        default { @('#2B2513', '#5A4B1F', '#F0C060') }
    }
    $w.Card.Background = New-WpfBrush $look[0]
    $w.Card.BorderBrush = New-WpfBrush $look[1]
    $w.CardBody.Children.Clear()
    [void]$w.CardBody.Children.Add((New-GuiLine $Title 15 $look[2] 'SemiBold'))
    # The messages are written for a console, broken into short lines; in the
    # card a sentence runs on as a paragraph. Indented lines (a list, steps)
    # and the large "*" lines keep their own.
    $joined = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $last = if ($joined.Count) { $joined[$joined.Count - 1] } else { $null }
        if ($null -ne $last -and $last -ne '' -and -not $last.StartsWith('*') -and -not $last.StartsWith(' ') -and
            $line -ne '' -and -not $line.StartsWith('*') -and -not $line.StartsWith(' ') -and
            $last -notmatch '[:.!?]$') {
            $joined[$joined.Count - 1] = "$last $line"
        } else {
            $joined.Add($line)
        }
    }
    foreach ($line in $joined) {
        if ($line.StartsWith('*')) {
            $thing = $line.Substring(1).Trim()
            $box = New-Object System.Windows.Controls.TextBox
            $box.Text = $thing
            $box.IsReadOnly = $true
            $box.BorderThickness = 0
            $box.Background = [System.Windows.Media.Brushes]::Transparent
            $box.Foreground = New-WpfBrush '#FFFFFF'
            $box.FontWeight = 'SemiBold'
            $box.TextWrapping = 'Wrap'
            $box.Margin = '0,4,0,4'
            # A code large; an address smaller, on one line; a sentence plain.
            if ($thing.Length -le 30) {
                $box.FontSize = 22
                $box.FontFamily = 'Cascadia Mono, Consolas'
            } elseif ($thing.Length -le 56 -and $thing -notmatch '\s') {
                $box.FontSize = 16
                $box.FontFamily = 'Cascadia Mono, Consolas'
            } else {
                $box.FontSize = 14
            }
            [void]$w.CardBody.Children.Add($box)
        } elseif ($line -eq '') {
            $gap = New-Object System.Windows.Controls.Border
            $gap.Height = 8
            [void]$w.CardBody.Children.Add($gap)
        } else {
            [void]$w.CardBody.Children.Add((New-GuiLine $line 14))
        }
    }
    $w.Card.Visibility = 'Visible'
    Update-Gui
}

# Expand-GuiMessage is the end: no more progress to show, the card is what
# is left to read.
function Expand-GuiMessage {
    $w = $script:Gui
    $w.ProgressPanel.Visibility = 'Collapsed'
    $w.Steps.Margin = '0,0,0,4'
}

# Show-GuiPage asks a question as a page in this window - the library, the
# network, keeping it available - and waits for one of its buttons, whose
# label it returns. Content is what the page shows; Buttons, right to left as
# read, the last the one to press. What was showing comes back after.
function Show-GuiPage($Content, [string[]]$Buttons, [string]$Primary = '') {
    $w = $script:Gui
    $wasProgress = $w.ProgressPanel.Visibility
    $wasCard = $w.Card.Visibility
    $wasSteps = $w.Steps.Visibility
    $w.ProgressPanel.Visibility = 'Collapsed'
    $w.Card.Visibility = 'Collapsed'
    # The steps step aside too, so a page's buttons fit a small laptop screen.
    $w.Steps.Visibility = 'Collapsed'
    $w.Page.Children.Clear()
    [void]$w.Page.Children.Add($Content)
    $w.PageScroll.Visibility = 'Visible'
    $w.PageScroll.ScrollToTop()
    $w.Page.Visibility = 'Visible'
    $w.PageButtons.Children.Clear()
    if (-not $Primary) { $Primary = $Buttons[$Buttons.Count - 1] }
    foreach ($label in $Buttons) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $label
        $b.Tag = $label
        $b.Style = $w.Window.FindResource($(if ($label -eq $Primary) { 'Primary' } else { 'Btn' }))
        $b.Add_Click({ param($s) $script:Gui.Choice = $s.Tag })
        if ($label -eq $Primary) { $b.IsDefault = $true }
        [void]$w.PageButtons.Children.Add($b)
    }
    $w.Buttons.Visibility = 'Collapsed'
    $w.PageButtons.Visibility = 'Visible'
    $w.Choice = $null
    if ($w.Window.WindowState -eq 'Minimized') { $w.Window.WindowState = 'Normal' }
    # In front of whatever was opened meanwhile: Windows keeps a background
    # process from taking the focus, so it is lifted above, then let go.
    $w.Window.Topmost = $true
    [void]$w.Window.Activate()
    $w.Window.Topmost = $false
    while ($null -eq $w.Choice -and $w.Window.IsVisible) {
        Update-Gui
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 30
    }
    $w.Page.Visibility = 'Collapsed'
    $w.PageScroll.Visibility = 'Collapsed'
    $w.PageButtons.Visibility = 'Collapsed'
    $w.Buttons.Visibility = 'Visible'
    $w.ProgressPanel.Visibility = $wasProgress
    $w.Card.Visibility = $wasCard
    $w.Steps.Visibility = $wasSteps
    return $w.Choice
}

# New-GuiPageText is a page's heading and words, ready for more below them.
function New-GuiPageText([string]$Heading, [string[]]$Lines) {
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-GuiLine $Heading 18 '#F2F2FA' 'SemiBold'))
    $gap = New-Object System.Windows.Controls.Border
    $gap.Height = 6
    [void]$panel.Children.Add($gap)
    foreach ($line in $Lines) {
        if ($line -eq '') {
            $g2 = New-Object System.Windows.Controls.Border
            $g2.Height = 8
            [void]$panel.Children.Add($g2)
        } else {
            [void]$panel.Children.Add((New-GuiLine $line 14 '#B9B9C6'))
        }
    }
    return $panel
}

# Wait-GuiClosed keeps the window up until the person closes it.
function Wait-GuiClosed {
    [void]$script:Gui.Window.Activate()
    while (-not $script:Gui.Closed -and $script:Gui.Window.IsVisible) {
        Update-Gui
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 40
    }
    # The relaunched copy is its own temporary file; it has been read.
    if ($PSCommandPath -and ([IO.Path]::GetFileName($PSCommandPath) -like 'soundstorm-setup-*.ps1')) {
        Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    }
}

function Complete-Gui([string]$Heading, [string]$Subheading, [string]$OpenUrl) {
    if (-not $script:Gui) { return }
    $w = $script:Gui
    $w.Running = $false
    $w.Progress = 1.0
    $w.Percent.Text = '100%'
    $w.Current = $w.StepRows.Count + 1
    Set-GuiStepMarks
    $w.Title.Text = $Heading
    $w.Title.Foreground = New-WpfBrush '#5FD39C'
    $w.Sub.Text = $Subheading
    Expand-GuiMessage
    $w.OpenUrl = $OpenUrl
    $w.OpenButton.Visibility = if ($OpenUrl) { 'Visible' } else { 'Collapsed' }
    $w.OpenButton.IsDefault = [bool]$OpenUrl
    $w.CloseButton.Content = 'Close'
    Wait-GuiClosed
}

function Stop-Gui([string]$Text, $Action = $null) {
    $w = $script:Gui
    $w.Running = $false
    # A restart on the way is the plan on a new PC, not a failure: said
    # calmly, in blue, with no log (the blind review: it read as a crash).
    if ($script:RestartStop) {
        Set-GuiStepMarks
        $w.Title.Text = 'One restart needed'
        $w.Title.Foreground = New-WpfBrush '#F2F2FA'
        $w.Sub.Text = 'Windows has to restart to finish installing what EmberStorm runs on. Nothing is lost.'
        Expand-GuiMessage
        Set-GuiMessage 'What happens next' @($Text -split "`r?`n" | ForEach-Object { $_ -replace '^  ', '' }) 'Cyan'
        $w.OpenButton.Visibility = 'Collapsed'
        $w.CloseButton.Content = 'Later'
        if ($Action) {
            $w.ActButton.Content = $Action.Label
            $w.ActButton.Tag = $Action.Run
            $w.ActButton.Add_Click({ param($s) & $s.Tag })
            $w.ActButton.Visibility = 'Visible'
            $w.ActButton.IsDefault = $true
        }
        Wait-GuiClosed
        return
    }
    Set-GuiStepMarks -Failed
    $w.Title.Text = 'EmberStorm could not finish'
    $w.Title.Foreground = New-WpfBrush '#FF8A8A'
    $w.Sub.Text = 'Nothing has been lost. What happened, and what to do, is below.'
    Expand-GuiMessage
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_ -replace '^  ', '' })
    if ($Text -notmatch [regex]::Escape($script:SetupLog)) {
        $lines += @('', "A full log is saved in $script:SetupLog")
    }
    Set-GuiMessage 'What went wrong' $lines 'Red'
    $w.ShowLog = $true
    $w.OpenButton.Content = 'Show log file'
    $w.OpenButton.Style = $w.Window.FindResource('Btn')
    $w.OpenButton.Visibility = 'Visible'
    $w.CloseButton.Content = 'Close'
    if (-not $Action -and $script:SelfPath) {
        $Action = @{ Label = 'Try again'; Run = { Restart-Setup } }
    }
    if ($Action) {
        $w.ActButton.Content = $Action.Label
        $w.ActButton.Tag = $Action.Run
        $w.ActButton.Add_Click({ param($s) & $s.Tag })
        $w.ActButton.Visibility = 'Visible'
        $w.ActButton.IsDefault = $true
    }
    Wait-GuiClosed
}

# Restart-Setup starts this setup again from the start, as a new window, and
# closes this one - the "Try again" of a failure, where people had to find the
# file they first downloaded (the window review).
function Restart-Setup {
    try {
        $copy = Join-Path $env:TEMP "soundstorm-setup-again-$PID.ps1"
        Copy-Item -LiteralPath $script:SelfPath $copy -Force
        if ($script:SetupMutex) { try { $script:SetupMutex.ReleaseMutex() } catch { } }
        $env:SOUNDSTORM_WINDOW = '1'
        $env:SOUNDSTORM_FRESH = '1'
        if ($AuthKey) { $env:SOUNDSTORM_TS_KEY = "$AuthKey" }
        # What was answered stays answered (the blind review: every question
        # came back, the auto sign-in walkthrough included).
        if ($script:QuestionsAsked) {
            $env:EMBERSTORM_ASKED = '1'
            if ($lanAccess) { $env:EMBERSTORM_LAN = "$lanAccess" }
            if ($Library) { $env:EMBERSTORM_LIBRARY = "$Library" }
        }
        if ($script:dockerInstalledNow) { $env:EMBERSTORM_DOCKER_OURS = '1' }
        if ($script:DockerOnSystem) { $env:EMBERSTORM_DOCKER_C = '1' }
        # The library chosen stays chosen even before every question was
        # answered (a room check can stop between them).
        if ($Library) { $env:EMBERSTORM_LIBRARY = "$Library" }
        Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -ArgumentList (@(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$copy`"") + (ConvertTo-ArgumentList $script:BoundArgs))
    } catch { }
    $script:Gui.Running = $false
    $script:Gui.Window.Close()
}

# ConvertTo-ArgumentList turns this run's parameters back into arguments, for
# the relaunch to receive exactly what this run was given.
function ConvertTo-ArgumentList($Bound) {
    $list = @()
    foreach ($key in $Bound.Keys) {
        $value = $Bound[$key]
        # The key rides in the environment, which the relaunched copy reads.
        if ($key -eq 'AuthKey') {
            $env:SOUNDSTORM_TS_KEY = "$value"
            continue
        }
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $list += "-$key" }
        } else {
            $list += "-$key"
            # A trailing backslash would escape the closing quote - "E:\" read
            # back as E:" and the rest of the line - and a drive root is exactly
            # where somebody saves a move. Doubled, it reads back as one.
            $text = "$value" -replace '"', ''
            if ($text.EndsWith('\')) { $text += '\' }
            $list += ('"' + $text + '"')
        }
    }
    return $list
}

# The relaunch. An interactive setup - not the desktop icon (-Launch), not
# -Console, not somewhere a window cannot be shown - starts itself again with
# its console hidden and the window as its face, and this console says so and
# goes. Exit code 99 tells EmberStorm-Setup.cmd not to wait for a key press
# under a message pointing somewhere else.
#
# The copy it runs is its own temporary file, because the file this run came
# from may be a downloaded copy its parent is about to delete.
$script:BoundArgs = $PSBoundParameters
$script:WindowWanted = (-not $Launch) -and (-not $Console) -and ($env:SOUNDSTORM_CONSOLE -ne '1') -and [Environment]::UserInteractive
if ($script:WindowWanted -and $env:SOUNDSTORM_WINDOW -ne '1' -and $PSCommandPath) {
    $canShow = $false
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
        $canShow = $true
    } catch {
    }
    if ($canShow) {
        $copy = Join-Path $env:TEMP "soundstorm-setup-$PID.ps1"
        Copy-Item -LiteralPath $PSCommandPath $copy -Force
        $env:SOUNDSTORM_WINDOW = '1'
        $env:SOUNDSTORM_FRESH = '1'
        $powershellExe = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $powershellExe -WindowStyle Hidden -ArgumentList (@(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$copy`"") +
            (ConvertTo-ArgumentList $PSBoundParameters))
        Microsoft.PowerShell.Utility\Write-Host ""
        Microsoft.PowerShell.Utility\Write-Host "  EmberStorm setup has opened in its own window." -ForegroundColor Green
        exit 99
    }
}

# One setup at a time: a second double-click while the first was still busy
# started two side by side (the window review). Not the desktop icon.
$script:SelfPath = $PSCommandPath
if (-not $Launch) {
    try {
        $script:SetupMutex = New-Object Threading.Mutex($false, 'Local\EmberStormSetup')
        $owned = $false
        try { $owned = $script:SetupMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                [void][System.Windows.Forms.MessageBox]::Show('EmberStorm setup is already running. Look for its window - it may be minimized in the taskbar.', 'EmberStorm Setup', 'OK', 'Information')
            } catch { }
            exit 0
        }
    } catch { }
}

# Output. Notes are Gray, not the DarkGray they used to be: on Windows
# PowerShell's default dark-blue console DarkGray is close to unreadable, and
# nearly everything this script says is something the person needs to read.
# Steps are Cyan so the numbered progress stands out from the detail under it.
function Step($text) { Write-Host ""; Write-Host "  $text" -ForegroundColor Cyan; Set-GuiStep $text }
function Note($text) { Write-Host "    $text" -ForegroundColor Gray; Set-GuiStatus $text 'Note' }
function Good($text) { Write-Host "    $text" -ForegroundColor Green; Set-GuiStatus $text 'Good' }
function Important($text) { Write-Host "    $text" -ForegroundColor Yellow; Set-GuiStatus $text 'Important' }

# Callout frames the few things somebody has to act on - what to click in
# Docker's windows, the code to type into the first screen - so they cannot be
# lost among the progress lines scrolling past. A line starting with "*" is the
# thing itself (a code, an address) and is drawn in the frame's color.
#
# ASCII only, like the rest of this file: it has no byte order mark, so
# Windows PowerShell reads it in the system code page, where box-drawing
# characters and dashes come out as mojibake.
function Callout([string]$Title, [string[]]$Lines, [ConsoleColor]$Color = 'Yellow') {
    Set-GuiMessage $Title $Lines "$Color"
    Write-Host ""
    Write-Host ("  +--- " + $Title + " " + ('-' * [Math]::Max(4, 62 - $Title.Length))) -ForegroundColor $Color
    foreach ($line in $Lines) {
        Write-Host "  |  " -ForegroundColor $Color -NoNewline
        if ($line.StartsWith('*')) {
            Write-Host $line.Substring(1) -ForegroundColor $Color
        } else {
            Write-Host $line -ForegroundColor White
        }
    }
    Write-Host ("  +" + ('-' * 69)) -ForegroundColor $Color
    Write-Host ""
}

# Show-DockerGuide says what Docker Desktop is about to ask, before it asks.
#
# Its first start opens a window of its own - terms, then an offer to sign in or
# create an account, then a survey - in front of a setup that is waiting on it.
# Somebody who has never heard of Docker cannot tell which of those matter, or
# whether the account is needed (it is not), or whether closing the window
# breaks something (it does not). Shown once per run, whichever comes first of
# installing Docker (which opens itself when it finishes) or starting it.
#
# Then most of it was answered for them (2026-10-07, the owner: "the most
# annoying part of install"). Docker's own installer accepts its terms with
# --accept-license (its documented switch for an unattended install, found in
# "Docker Desktop Installer.exe"), and Docker skips its sign-in and survey
# when its settings already say DisplayedOnboarding - the key it writes
# itself once they are done (seen in this PC's settings-store.json, and in
# Docker.Core.dll). So a Docker installed by this setup asks nothing.
#
# A Docker already on the PC but never opened has not had its terms accepted,
# and that is the person's to do, not this script's: it is asked for in a
# window that only closes with "I understand" - the one click left.
$script:dockerGuideShown = $false
$script:dockerInstalledNow = $false
function Show-DockerGuide([switch]$FirstRun) {
    if ($script:dockerGuideShown) { return }
    $script:dockerGuideShown = $true
    # A Docker set up before: nothing to say.
    if (-not $script:dockerInstalledNow -and -not $FirstRun) { return }
    # Installed by this setup, in this run or the one before a restart.
    if ($script:dockerInstalledNow -or $env:EMBERSTORM_DOCKER_OURS -eq '1') {
        Callout 'Docker Desktop' @(
            'EmberStorm runs inside a free program called Docker Desktop.',
            'Setup installs and starts it, and answers its first questions for',
            'you - there is nothing to click in Docker, and no Docker account',
            'is needed.',
            '',
            'Docker Desktop is free for personal use and small businesses.',
            'Installing it accepts Docker''s terms:',
            '  docker.com/legal/docker-subscription-service-agreement',
            '',
            'If a Docker window opens anyway: accept its terms and Skip anything',
            'else, then come back here. Closing Docker''s window is fine - it',
            'keeps running in the background.'
        ) 'Cyan'
        return
    }
    Callout 'Docker Desktop will ask one thing' @(
        'Docker Desktop is already on this PC but has not been opened yet.',
        'When it starts, it asks you to accept its terms:',
        '',
        '*  Subscription Service Agreement  ->  click Accept',
        '',
        'Setup skips Docker''s sign-in and questions for you - no Docker',
        'account is needed. Then come back to THIS window: setup carries on',
        'by itself as soon as Docker is ready.'
    ) 'Cyan'
    # Read, not just shown: a box in the setup window is easy to walk away
    # from, and the setup would then sit waiting on that one click. Never on
    # the desktop icon's path (-Launch), which runs minimized at sign-in.
    if (-not $Launch) { Confirm-DockerGuide }
}

# Test-DockerFirstRun is whether Docker Desktop has yet to show its first-run
# window: it records the accepted terms (LicenseTermsVersion) in its settings
# file once somebody clicks Accept. Missing file, or no record, is a first run.
function Test-DockerFirstRun {
    $store = Join-Path $env:APPDATA 'Docker\settings-store.json'
    if (-not (Test-Path $store)) { return $true }
    try {
        return -not ((Get-Content -Raw -LiteralPath $store) -match '"LicenseTermsVersion"')
    } catch {
        return $true
    }
}

# Confirm-DockerGuide shows what Docker is about to ask and waits for
# "I understand". The window has no close button, so the only way on is to
# have read it; the console fallback asks for Enter.
function Confirm-DockerGuide {
    $text = "EmberStorm runs inside a free program called Docker Desktop. It is already on this PC but has not been opened yet, so when setup starts it, Docker opens a window asking you to accept its terms:`r`n`r`n" +
        "    Subscription Service Agreement  ->  click Accept`r`n`r`n" +
        "That is the only thing to click: setup skips Docker's sign-in and questions for you, and no Docker account is needed.`r`n`r`n" +
        "Setup cannot finish until you click Accept. Stay at the computer until Docker's window appears, then come back to this setup - it carries on by itself."
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
    } catch {
        try {
            [void](Read-Host '    Docker will open a window asking you to accept its terms: click Accept. Press Enter once you have read this')
        } catch { }
        return
    }
    if ($script:Gui) {
        $page = New-GuiPageText 'Docker will ask one thing' @(
            'EmberStorm runs inside a free program called Docker Desktop. It is already on this PC but has not been opened yet, so when setup starts it, Docker opens a window asking you to accept its terms:',
            '',
            '    Subscription Service Agreement  ->  click Accept',
            '',
            'That is the only thing to click: setup skips Docker''s sign-in and questions for you, and no Docker account is needed. Stay at the computer until Docker''s window appears, then come back here - setup carries on by itself.')
        [void](Show-GuiPage $page @('I understand'))
        return
    }
    Note "A window has opened: read it, then click I understand."
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'EmberStorm - Docker will ask one thing'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ControlBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.ClientSize = New-Object System.Drawing.Size(560, 360)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.Location = New-Object System.Drawing.Point(20, 16)
    $label.Size = New-Object System.Drawing.Size(520, 280)
    $form.Controls.Add($label)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'I understand'
    $ok.Location = New-Object System.Drawing.Point(384, 308)
    $ok.Size = New-Object System.Drawing.Size(156, 36)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok
    try {
        # Alt+F4 still closes a window without a close button; that is not
        # "I understand", so it asks again.
        while ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { }
    } finally {
        $form.Dispose()
    }
}

# Stop says why it stopped and what to do about it. An installer that reports
# "error: 1" has failed twice.
#
# In -Launch mode it also puts the message in a dialog box. That path runs from
# a desktop shortcut with a minimized window, so console text is written where
# nobody will ever see it - the failure just looks like clicking the icon did
# nothing at all.
function Stop-With($text, $Action = $null) {
    Write-Host ""
    Write-Host "  EmberStorm could not finish." -ForegroundColor Red
    Write-Host ""
    Write-Host $text
    Write-Host ""
    if ($Launch) { Show-Problem $text }
    if ($script:Gui) { Stop-Gui $text $Action }
    exit 1
}

# Register-Resume has Windows start this setup once more, by itself, the next
# time this person signs in: a fresh PC usually needs a restart part way
# (Windows Subsystem for Linux, Docker, or virtualization switched on in the
# BIOS), and people restarted and then never knew to run it again. The copy
# it starts is kept in the person's own folder (the file this run came from
# may be a temporary one) and is named so it fetches the newest setup first.
# Returns $true once arranged.
$script:ResumeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
function Register-Resume {
    # Not for a console run (its prompts would be in a window nobody sees),
    # and not more than three times: a setup that keeps stopping at the same
    # place stops asking at every sign-in (a review).
    if ($Launch -or $Console -or -not $PSCommandPath) { return $false }
    $resumes = 0
    if ("$env:EMBERSTORM_RESUMES" -match '^\d+$') { $resumes = [int]$env:EMBERSTORM_RESUMES }
    if ($resumes -ge 3) { return $false }
    try {
        $folder = Join-Path $env:LOCALAPPDATA 'EmberStorm'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $copy = Join-Path $folder 'soundstorm-install.ps1'
        if ($PSCommandPath -ne $copy) { Copy-Item -LiteralPath $PSCommandPath $copy -Force }
        $powershellExe = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # What the environment chose, for the run after the restart, kept
        # beside the copy (the command itself has a length limit).
        $keep = @("SOUNDSTORM_DIR=$Dir", "EMBERSTORM_RESUMES=$($resumes + 1)")
        # The questions already answered, so the run after the restart does
        # not ask them again (or lose a library folder chosen in the window).
        if ($script:QuestionsAsked) {
            $keep += 'EMBERSTORM_ASKED=1'
            if ($lanAccess) { $keep += "EMBERSTORM_LAN=$lanAccess" }
            if ($Library -and "$Library" -notmatch "[\r\n]") { $keep += "EMBERSTORM_LIBRARY=$Library" }
        }
        # Docker installed by this setup, its terms accepted: after the
        # restart nobody is asked to click Accept in a window that never comes.
        if ($script:dockerInstalledNow -or $env:EMBERSTORM_DOCKER_OURS -eq '1') { $keep += 'EMBERSTORM_DOCKER_OURS=1' }
        if ($script:DockerOnSystem -or $env:EMBERSTORM_DOCKER_C -eq '1') { $keep += 'EMBERSTORM_DOCKER_C=1' }
        if ($Library -and "$Library" -notmatch "[\r\n]" -and -not $script:QuestionsAsked) { $keep += "EMBERSTORM_LIBRARY=$Library" }
        # Never where to download from: a file in the person's folder must
        # not be able to point the next run elsewhere (the blind review).
        foreach ($name in @('SOUNDSTORM_PORT')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ($value -and $value -notmatch "[\r\n]") { $keep += "$name=$value" }
        }
        [IO.File]::WriteAllLines($script:ResumeFile, [string[]]$keep)
        $arguments = @(ConvertTo-ArgumentList $script:BoundArgs) -join ' '
        $command = "`"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$copy`" $arguments"
        if (-not (Test-Path $script:ResumeKey)) { New-Item -Path $script:ResumeKey -Force | Out-Null }
        Set-ItemProperty -Path $script:ResumeKey -Name 'EmberStormSetup' -Value $command.Trim() -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Clear-Resume takes that back: a setup run by hand meanwhile does not want a
# second one starting at the next sign-in.
function Clear-Resume {
    Remove-ItemProperty -Path $script:ResumeKey -Name 'EmberStormSetup' -ErrorAction SilentlyContinue
}

# Stop-ForRestart is a stop whose cure is a restart: arranged to carry on by
# itself afterwards, with a button that restarts now.
function Stop-ForRestart([string]$Text) {
    $script:RestartStop = $true
    $after = if (Register-Resume) {
        "`n`n  After the restart, sign in and the setup carries on by itself: its window comes back on its own within a minute or two."
    } else { '' }
    Stop-With ($Text + $after) @{
        Label = 'Restart now'
        Run   = {
            $sure = [System.Windows.MessageBox]::Show($script:Gui.Window,
                "Restart this PC now?`r`n`r`nAny other programs still open will be closed, so save your work in them first.`r`n`r`nYes - restart now.`r`nNo - not yet. Restart when you are ready; the setup carries on by itself once you sign back in.",
                'EmberStorm Setup', 'YesNo', 'Question')
            if ("$sure" -eq 'Yes') {
                Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\shutdown.exe') -ArgumentList '/r', '/t', '0' -WindowStyle Hidden
            }
        }
    }
}

# Confirm-TryAgain asks, after Windows' permission question was refused or
# dismissed, whether to ask again - most often it was a misclick, and stopping
# the whole setup for one was a dead end. $false where no window can be shown.
function Confirm-TryAgain([string]$What, [switch]$Optional) {
    if (-not $script:Gui) { return $false }
    if ($Optional) {
        $page = New-GuiPageText 'Windows needs your permission' @(
            "Windows asked for permission to $What, and it was not given.",
            '',
            'Choose Ask again, then Yes when Windows asks - or Skip this, and EmberStorm works on this PC only for now.')
        return ((Show-GuiPage $page @('Skip this', 'Ask again')) -eq 'Ask again')
    }
    $page = New-GuiPageText 'Windows needs your permission' @(
        "Windows asked for permission to $What, and it was not given. EmberStorm cannot be set up without it.",
        '',
        'Choose Ask again, then Yes when Windows asks.')
    return ((Show-GuiPage $page @('Stop the setup', 'Ask again')) -eq 'Ask again')
}

# Save-EmberStormLog puts EmberStorm's own recent log into the setup log, so
# that when it will not start, the one file somebody is asked to send already
# has what whoever helps them needs. The alternative was printing
# "cd <folder>; docker compose logs" at a person who has never opened a
# terminal.
#
# EmberStorm's log only: the media servers' logs are not held to carrying no
# credential - a Subsonic request carries its credential in the query string -
# and this file is one people are told to send to somebody. EmberStorm's own
# does carry one thing: until an account exists it logs the setup code, which
# is exactly when a failed setup sends this file. So Protect-SetupLog takes it
# out.
function Save-EmberStormLog {
    try {
        $logs = Invoke-Docker @('compose', '--project-directory', $Dir, 'logs', '--no-color', '--tail', '200', 'soundstorm') -Capture
        [IO.File]::AppendAllText($script:SetupLog,
            "`r`n----- EmberStorm's own log (last 200 lines) -----`r`n$($logs.Output)`r`n")
    } catch {
        # The setup log still says what the setup saw.
    }
    Protect-SetupLog
}

# Protect-SetupLog removes the setup code from the setup log, however it was
# written: EmberStorm's "code=" and "?setup=", and the code shown in the
# finished window in groups of four. Whoever has the code can create the
# owner's account on a server that has none yet.
function Protect-SetupLog {
    try {
        if (-not (Test-Path $script:SetupLog)) { return }
        $text = [IO.File]::ReadAllText($script:SetupLog)
        $clean = $text -replace '(?i)(setup=)[^\s"&]+', '$1[removed]' -replace '(?i)(\bcode=)\S+', '$1[removed]'
        # Get-EnvSetting is defined further down; a failure before the script
        # reaches it must still have the rest taken out.
        $code = $null
        try { $code = Get-EnvSetting 'SOUNDSTORM_SETUP_CODE' } catch { }
        if ($code) {
            $chars = ($code -replace '[^A-Za-z0-9]', '').ToCharArray() | ForEach-Object { [regex]::Escape([string]$_) }
            if ($chars.Count -ge 8) {
                $clean = [regex]::Replace($clean, '(?i)' + ($chars -join '[\s-]*'), '[setup code removed]')
            }
        }
        if ($clean -ne $text) { [IO.File]::WriteAllText($script:SetupLog, $clean) }
    } catch {
        # Leave the log as it is rather than lose it.
    }
}

# Get-HelpAdvice is what to do when EmberStorm will not start, in words rather
# than commands.
function Get-HelpAdvice {
    Protect-SetupLog
    $open = if ($script:Gui) { " - the Show log file button opens the folder it is in" } else { '' }
    $again = if ($script:Gui) { 'press Try again' } else { 'run this setup again' }
    return @"
  Restart the PC and $again - that fixes it more often than not, and
  nothing you have downloaded is lost.

  If it happens again, send this file to whoever helps you with EmberStorm${open}:

    $script:SetupLog
"@
}

function Show-Problem($text) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        # 120 seconds rather than 0: at startup there may be nobody to click
        # it, and a modal box waiting forever would keep the process alive.
        # 48 is the warning icon.
        $shell.Popup($text, 120, 'EmberStorm', 48) | Out-Null
    } catch {
        # A dialog is a nicety; failing to show one must not become the error.
    }
}

# Invoke-DockerBounded runs docker with a deadline.
#
# `compose up -d` normally takes seconds, but it will sit for a very long time
# trying to reach a registry it cannot. From a minimized shortcut that is
# indistinguishable from the icon doing nothing, so the launcher gives it a
# limit and reports rather than waiting.
# Every compose command names its file: left to itself, compose also reads a
# docker-compose.override.yml (or a compose.yaml) it finds in the folder, which
# somebody else could have put there (the twelfth security pass).
function Add-ComposeFile([string[]]$Arguments, [switch]$Quoted) {
    if (-not $Arguments -or $Arguments[0] -ne 'compose' -or $Arguments -contains '-f') { return $Arguments }
    $file = Join-Path $Dir 'docker-compose.yml'
    if ($Quoted) { $file = '"' + $file + '"' }
    $rest = @()
    if ($Arguments.Count -gt 1) { $rest = $Arguments[1..($Arguments.Count - 1)] }
    return @('compose', '-f', $file) + $rest
}

function Invoke-DockerBounded {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 120)

    $Arguments = Add-ComposeFile $Arguments -Quoted
    $process = Start-Process -FilePath 'docker' -ArgumentList $Arguments `
        -NoNewWindow -PassThru
    # Reading .Handle is not a no-op and is not optional. Start-Process
    # -PassThru hands back a Process object with no cached handle, and without
    # one WaitForExit(timeout) never observes the exit - it returns false at
    # the deadline for a program that finished in a second. The symptom is
    # every launch taking exactly as long as the timeout and then reporting
    # failure, with the containers running perfectly well behind it.
    if (-not (Wait-ProcessPumped $process $TimeoutSeconds)) {
        try { $process.Kill() } catch {}
        return 1
    }
    return $process.ExitCode
}

# Read-DockerLines runs docker and hands on each line it prints, keeping the
# window answering while it is silent - read in the pipeline, a download that
# went quiet (a dropped connection) froze the window as "Not responding" (the
# blind review). Silent for StallSeconds, it is stopped. Its exit code is left
# in $script:DockerExit.
function Read-DockerLines([string[]]$Arguments, [int]$StallSeconds = 900) {
    $exe = (Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($psi)
    $readers = @($process.StandardOutput, $process.StandardError)
    $tasks = @($null, $null)
    $last = Get-Date
    while ($readers[0] -or $readers[1]) {
        $got = $false
        for ($i = 0; $i -lt 2; $i++) {
            if (-not $readers[$i]) { continue }
            if (-not $tasks[$i]) { $tasks[$i] = $readers[$i].ReadLineAsync() }
            if ($tasks[$i].IsCompleted) {
                $line = $tasks[$i].Result
                $tasks[$i] = $null
                if ($null -eq $line) { $readers[$i] = $null } else { $got = $true; $last = Get-Date; $line }
            }
        }
        if (-not $got) {
            Update-Gui
            [Threading.Thread]::Sleep(80)
            if (((Get-Date) - $last).TotalSeconds -gt $StallSeconds) {
                try { $process.Kill() } catch { }
                'The download stopped answering.'
                break
            }
        }
    }
    $process.WaitForExit()
    $script:DockerExit = $process.ExitCode
}

# Invoke-Docker runs docker with stderr made harmless.
#
# PowerShell 5.1 wraps every stderr line from a native program in an
# ErrorRecord, and with $ErrorActionPreference = 'Stop' the first one throws.
# docker compose writes its ordinary progress to stderr, so `compose up` failed
# this script by succeeding noisily. Anything that shells out goes through here.
function Invoke-Docker {
    param([string[]]$Arguments, [switch]$Capture, [switch]$Calm)

    $Arguments = Add-ComposeFile $Arguments

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Capture) {
            $lines = & docker @Arguments 2>&1 | ForEach-Object { Update-Gui; "$_" }
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = ($lines -join [Environment]::NewLine)
            }
        }
        if ($Calm) {
            $lastBeat = Get-Date
            # What was shown is kept, so a failure can be told apart by what
            # it said - a rate limit wants waiting out, not a new connection.
            $kept = New-Object System.Collections.Generic.List[string]
            # Which images are still coming, by name. The heartbeat used to
            # say only "still downloading...", right under the last image
            # that had *finished* - so that one looked like the slow one.
            # Somebody asked why Valkey, the smallest image of all, took for
            # ever.
            $pending = New-Object System.Collections.Generic.List[string]
            $total = 0
            $done = 0
            # Bytes, from the progress lines docker prints for each layer
            # ("a1b2c3d4e5f6 Downloading [==>  ] 45.6MB/1.2GB"): with the
            # images' count, what moves the bar - images differ a hundredfold
            # in size, so the count alone jumped and then sat.
            $layers = @{}
            $units = @{ 'B' = 1.0; 'kB' = 1e3; 'MB' = 1e6; 'GB' = 1e9 }
            $lastBar = Get-Date
            $script:DockerExit = 1
            Read-DockerLines $Arguments | ForEach-Object {
                Update-Gui
                $line = "$_"
                if ($line -match '^\s*([0-9a-f]{12})\s+Downloading\s+\[[^\]]*\]\s+([\d.]+)\s*([kKMG]?B)/([\d.]+)\s*([kKMG]?B)') {
                    $layers[$Matches[1]] = @(([double]$Matches[2] * $units[$Matches[3]]), ([double]$Matches[4] * $units[$Matches[5]]))
                } elseif ($line -match '^\s*([0-9a-f]{12})\s+(Download complete|Pull complete|Extracting)' -and $layers.ContainsKey($Matches[1])) {
                    $layers[$Matches[1]][0] = $layers[$Matches[1]][1]
                }
                if (((Get-Date) - $lastBar).TotalSeconds -ge 1 -and $total -gt 0) {
                    $lastBar = Get-Date
                    $got = 0.0; $known = 0.0
                    foreach ($v in $layers.Values) { $got += $v[0]; $known += $v[1] }
                    $byCount = $done / $total
                    $byBytes = if ($known -gt 0) { $got / $known } else { 0 }
                    Set-GuiStepProgress ([Math]::Max($byCount, $byBytes) * 0.97)
                    if ($got -gt 0) { Set-GuiStatus ("Downloaded {0} of {1} media servers - {2:N1} GB so far" -f $done, $total, ($got / 1e9)) }
                }
                if ($line -match '^\s*(?:Image\s+)?(\S+)\s+(Pulling|Pulled|Interrupted|Error)\s*$') {
                    $image = $Matches[1]
                    if ($Matches[2] -eq 'Pulling') {
                        if (-not $pending.Contains($image)) { $pending.Add($image); $total++ }
                    } else {
                        $wasPending = $pending.Remove($image)
                        # Counted up, "3 of 12", as people expect a download
                        # to count - not down from 12 to 0, as the heartbeat
                        # used to.
                        if ($Matches[2] -eq 'Pulled' -and $wasPending) {
                            $done++
                            Write-Host "  Downloaded $done of ${total}: $(($image -split '/')[-1] -replace ':.*$', '')"
                            $kept.Add($line)
                            $lastBeat = Get-Date
                            return
                        }
                    }
                }
                if (Test-DockerChurn $line) {
                    # Swallowed, but not silently: a download this long with
                    # nothing on screen is how somebody decides it has hung
                    # and closes the window.
                    if (((Get-Date) - $lastBeat).TotalSeconds -ge 30) {
                        if ($pending.Count -gt 0) {
                            # "jellyfin", not "jellyfin/jellyfin:latest".
                            $names = @($pending | ForEach-Object { ($_ -split '/')[-1] -replace ':.*$', '' })
                            Note "Still downloading - $done of ${total} media servers done."
                        } else {
                            Note "still downloading..."
                        }
                        $lastBeat = Get-Date
                    }
                    return
                }
                Write-Host $line
                $kept.Add($line)
                $lastBeat = Get-Date
            }
            return [pscustomobject]@{ ExitCode = $script:DockerExit; Output = ($kept -join [Environment]::NewLine) }
        } else {
            # Piped through Write-Host rather than run bare: without this the
            # stderr lines still arrive as ErrorRecords and print as a red
            # NativeCommandError block, which looks like a crash to anybody
            # who has not seen one before. docker reports progress there.
            & docker @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = '' }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

# Test-DockerChurn picks out the lines docker prints over and over.
#
# Given a terminal, docker redraws one progress block in place. Given a pipe
# it cannot, and falls back to printing a whole line per progress tick - so a
# 3GB pull becomes many hundreds of lines of hex and megabytes scrolling past.
# The first person to install this watched that for ten minutes, which reads
# far more like a fault than like progress.
#
# The pipe is not the thing to remove: it is what stops docker's stderr
# arriving as ErrorRecords and printing as a red block that looks like a
# crash. So the churn is dropped here instead, and the milestones - what is
# being pulled, what finished, anything that went wrong - are kept.
function Test-DockerChurn([string]$Line) {
    # The colon is optional and that is the whole point: `docker pull` writes
    # "5c3b447848a9: Extracting", `docker compose pull` writes
    # "f5be9333d3a8 Extracting" with no colon at all - and compose is what
    # this script runs. A first version of this regexp required the colon and
    # would have filtered nothing whatsoever on the one command it is for.
    return $Line -match '^\s*[0-9a-f]{8,}:?\s+(Extracting|Downloading|Download complete|Waiting|Pulling fs layer|Verifying Checksum|Already exists|Pull complete)\b'
}

# Invoke-Native runs an external program without its stderr becoming fatal.
#
# PowerShell 5.1 wraps every stderr line from a native program in an
# ErrorRecord, and with $ErrorActionPreference = 'Stop' the first one throws.
# That is not a stylistic problem: `docker info` writes to stderr when the
# engine is not running, so the check for "is Docker running" crashed instead
# of answering false - in exactly the situation it exists to detect, which is
# the situation immediately after installing Docker Desktop.
#
# Every external call in this script goes through here or through Invoke-Docker.
function Invoke-Native {
    param([string]$Command, [string[]]$Arguments, [switch]$Show)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Show) {
            # Printed as it arrives rather than collected: a multi-minute
            # download with a silent window is how somebody decides it hung.
            & $Command @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = '' }
        }
        $result = @(Invoke-Pumped {
            param($command, $arguments, $folder)
            $ErrorActionPreference = 'Continue'
            if ($folder) { Set-Location -LiteralPath $folder }
            try {
                $lines = @(& $command @arguments 2>&1 | ForEach-Object { "$_" })
            } catch {
                $lines = @($_.Exception.Message)
            }
            # Fresh on this thread: still nothing means it never ran.
            $code = if ($null -eq $LASTEXITCODE) { 1 } else { $LASTEXITCODE }
            [pscustomobject]@{ ExitCode = $code; Output = ($lines -join [Environment]::NewLine) }
        } @($Command, $Arguments, (Get-Location).ProviderPath))
        return $result[-1]
    } catch {
        return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Test-DockerRunning {
    return ((Invoke-Native 'docker' @('info')).ExitCode -eq 0)
}

function Get-DockerDesktopPath {
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe')
    )) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

# Hide-DockerDashboard stops Docker Desktop opening its window on every start.
#
# Only called immediately after installing it, so this sets a default on a
# fresh install rather than overriding a choice somebody made. Nobody who
# installs EmberStorm wants a Docker dashboard in their face at every login -
# the whole premise is that they never learn Docker is there.
#
# Written without a byte order mark: PowerShell 5.1's Set-Content -Encoding
# utf8 adds one, and a BOM in front of a JSON document is a good way to find
# out whether the reader is strict.
function Hide-DockerDashboard {
    param([switch]$Quiet)

    try {
        $dir = Join-Path $env:APPDATA 'Docker'
        $file = Join-Path $dir 'settings-store.json'
        if (-not (Test-Path $file)) {
            $legacy = Join-Path $dir 'settings.json'
            if (Test-Path $legacy) { $file = $legacy }
        }

        if (Test-Path $file) {
            $settings = Get-Content $file -Raw | ConvertFrom-Json
        } else {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $settings = New-Object psobject
        }

        # -Force so this works whether or not the key is already there. Docker
        # only writes settings that differ from its defaults, so on a fresh
        # install it will be absent.
        $settings | Add-Member -NotePropertyName 'OpenUIOnStartupDisabled' `
            -NotePropertyValue $true -Force
        # Its sign-in and survey, marked done as Docker marks them itself
        # (see Show-DockerGuide). Its terms are not: those are accepted by
        # its installer's --accept-license when this setup installs it, or by
        # the person.
        $settings | Add-Member -NotePropertyName 'DisplayedOnboarding' `
            -NotePropertyValue $true -Force

        $json = $settings | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($file, $json, (New-Object Text.UTF8Encoding $false))
        if (-not $Quiet) {
            Note "Docker Desktop will stay out of the way in the system tray."
        }
    } catch {
        # Cosmetic. Never worth failing an install over.
    }
}

# Get-LanAddress is this machine's address on the local network.
#
# Needed because the container cannot work this out for itself - inside Docker
# the only addresses visible are the container's own - and because telling
# somebody their media server is at "localhost" is useless the moment they pick
# up a phone.
#
# 192.168 first, then 10., then the 172.16-31 range, because that last one is
# also where Docker and WSL put their virtual adapters and those reach nothing.
function Get-LanAddress {
    try {
        $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -notlike '127.*' -and
                $_.IPAddress -notlike '169.254.*' -and
                $_.PrefixOrigin -ne 'WellKnown'
            } | Sort-Object InterfaceMetric

        foreach ($pattern in @('192.168.*', '10.*', '172.*')) {
            $match = $addresses | Where-Object { $_.IPAddress -like $pattern } | Select-Object -First 1
            if ($match) { return $match.IPAddress }
        }
        if ($addresses) { return ($addresses | Select-Object -First 1).IPAddress }
    } catch {
        # Not worth a failed install.
    }
    return $null
}

# Get-Gateway is the home router's LAN address - the default route's next hop -
# so remote access can ask it to open the port (NAT-PMP/PCP). The container
# cannot find this itself, for the same reason it cannot find the LAN address:
# its own default route is the Docker bridge, not the router.
#
# The same private-range order as Get-LanAddress, because Docker's and WSL's
# virtual adapters have default routes of their own in the 172 range that reach
# nothing. A real gateway is on-link and never 0.0.0.0.
function Get-Gateway {
    try {
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric, InterfaceMetric

        foreach ($pattern in @('192.168.*', '10.*', '172.*')) {
            $match = $routes | Where-Object { $_.NextHop -like $pattern } | Select-Object -First 1
            if ($match) { return $match.NextHop }
        }
        if ($routes) { return ($routes | Select-Object -First 1).NextHop }
    } catch {
        # Not worth a failed install; remote access just falls back to a manual
        # port-forward.
    }
    return $null
}

# Get-UpnpUrl discovers the router's UPnP device-description URL over SSDP, the
# fallback for opening the port when the router speaks UPnP but not NAT-PMP/PCP.
#
# Done here, on the host, because SSDP is multicast to 239.255.255.250 and that
# does not cross the Docker bridge into the container - the same reason the
# gateway is discovered here. The SOAP that uses this URL later is ordinary
# unicast and does work from the container.
function Get-UpnpUrl([string]$Gateway = '') {
    if (-not $Gateway) { $Gateway = Get-EnvSetting 'SOUNDSTORM_GATEWAY' }
    # Asked of the router directly first, then of the whole network. The
    # multicast search goes out whichever adapter Windows picks for multicast,
    # which on a PC with Tailscale or WSL is often not the one the router is
    # on - on the development machine it found nothing while the router
    # answered a search sent straight to it at once. An answer only counts
    # when it comes from the gateway: anything else on the network that
    # answers is not the router whose port is being opened.
    $targets = @()
    if ($Gateway) { $targets += $Gateway }
    $targets += '239.255.255.250'
    foreach ($target in $targets) {
        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = 2000
            $dst = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($target)), 1900
            $msg = "M-SEARCH * HTTP/1.1`r`n" +
                   "HOST: ${target}:1900`r`n" +
                   "MAN: `"ssdp:discover`"`r`n" +
                   "MX: 2`r`n" +
                   "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1`r`n`r`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($msg)
            [void]$udp.Send($bytes, $bytes.Length, $dst)

            $deadline = (Get-Date).AddSeconds(3)
            while ((Get-Date) -lt $deadline) {
                try {
                    $from = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
                    $data = $udp.Receive([ref]$from)
                } catch {
                    break  # receive timeout: nothing more is coming
                }
                $text = [System.Text.Encoding]::ASCII.GetString($data)
                foreach ($line in ($text -split "`r`n")) {
                    if ($line -match '(?i)^location:\s*(\S+)') {
                        $location = $Matches[1].Trim()
                        $locationHost = ''
                        try { $locationHost = ([Uri]$location).Host } catch { }
                        # Only the gateway's own answer, and only when the
                        # gateway is known: anything else on the network can
                        # answer a search (the twelfth security pass).
                        if ($Gateway -and $locationHost -eq $Gateway -and $location -match '^http://\S+$') {
                            return $location
                        }
                    }
                }
            }
        } catch {
            # UPnP is a best-effort fallback; NAT-PMP/PCP or a manual forward remain.
        } finally {
            if ($udp) { $udp.Close() }
        }
    }
    return $null
}

# There is deliberately no ".local" name printed on Windows.
#
# An earlier version printed "<computer>.local" as the address to use, having
# checked that it resolved. That check was worthless: it ran on the machine
# itself, where Windows answers for its own hostname regardless, so it proved
# nothing about whether a phone could resolve it. It passed on the development
# machine and failed on the first other PC it was tried on.
#
# The reason is that Windows does not reliably advertise its hostname over
# mDNS. What was answering on port 5353 here turned out to be calibre-server
# and steamwebhelper - unrelated applications that happen to run a responder -
# with no Bonjour service installed at all. macOS and Linux with avahi do
# advertise properly, which is why install.sh still offers it there.
#
# An address that works everywhere beats a nicer one that works on the machine
# that printed it.

# --- other devices on the network ---------------------------------------------
#
# Reaching EmberStorm from a phone was the one thing a laptop install could not
# do, and the installer only ever said "allow it through the firewall" in gray.
# Two things stand in the way, and neither is visible from the PC itself:
#
#   * Windows marks every new Wi-Fi network Public - the setting for cafes -
#     and a Public network lets nothing in.
#   * The first time Docker publishes a port, Windows asks whether "Docker
#     Desktop Backend" (com.docker.backend.exe, which is what accepts the
#     connections) may use networks. Its default ticks Private only, and
#     whatever is unticked - or everything, if the dialog is dismissed - gets
#     a Block rule, which beats any Allow.
#
# So after EmberStorm is running (and after that dialog has done whatever it
# did), the installer checks both and puts them right, with the person's say-so
# for anything that changes how Windows trusts a network. Only Private networks
# are ever opened: a network somebody has told Windows is their home, where the
# router already keeps the internet out unless they forward a port - which is
# exactly the case remote access needs this rule for.

# Named as it was before the rename, so an existing rule is found again.
$script:LanRuleName = 'SoundStorm - other devices on your home network'

# Get-LanProfile is the Windows network profile of the adapter holding Address:
# Category is Public, Private or DomainAuthenticated.
function Get-LanProfile([string]$Address) {
    try {
        $ip = Get-NetIPAddress -IPAddress $Address -ErrorAction Stop | Select-Object -First 1
        $network = Get-NetConnectionProfile -InterfaceIndex $ip.InterfaceIndex -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            Category       = [string]$network.NetworkCategory
            InterfaceIndex = [int]$ip.InterfaceIndex
            Name           = [string]$network.Name
        }
    } catch {
        return $null
    }
}

# Get-DockerPrivateBlocks lists the enabled inbound Block rules for Docker's
# listener that apply on Private networks - what a dismissed or default-answered
# firewall dialog leaves behind, and what would beat the Allow rule below.
function Get-DockerPrivateBlocks {
    try {
        return @(Get-NetFirewallApplicationFilter -ErrorAction Stop |
            Where-Object { $_.Program -like '*\com.docker.backend.exe' } |
            Get-NetFirewallRule -ErrorAction Stop |
            Where-Object {
                "$($_.Direction)" -eq 'Inbound' -and "$($_.Action)" -eq 'Block' -and
                "$($_.Enabled)" -eq 'True' -and "$($_.Profile)" -match 'Private|Any'
            })
    } catch {
        return @()
    }
}

# Test-LanAccessReady says whether a Private network already lets other devices
# in: EmberStorm's Allow rule is there for this port, and nothing blocks
# Docker's listener on Private. Readable without administrator, which is what
# keeps an update from asking for permission every time.
# DockerRuleName names the rules the setup gives Docker's backend ahead of its
# first start (Enable-LanAccess).
$script:DockerRuleName = 'EmberStorm - Docker Desktop Backend'

# Test-DockerRulesReady says whether Docker's backend already has a rule, so
# Windows will not ask about it.
function Test-DockerRulesReady {
    try {
        return @(Get-NetFirewallApplicationFilter -ErrorAction Stop |
            Where-Object { $_.Program -like '*\com.docker.backend.exe' }).Count -gt 0
    } catch {
        return $false
    }
}

function Test-LanAccessReady([int]$Port) {
    try {
        $ours = @(Get-NetFirewallRule -DisplayName $script:LanRuleName -ErrorAction Stop |
            Where-Object { "$($_.Enabled)" -eq 'True' -and "$($_.Action)" -eq 'Allow' })
        $portOk = $false
        foreach ($rule in $ours) {
            if (@(($rule | Get-NetFirewallPortFilter).LocalPort) -contains "$Port") { $portOk = $true }
        }
        if (-not $portOk) { return $false }
    } catch {
        return $false
    }
    return (Get-DockerPrivateBlocks).Count -eq 0
}

# Enable-LanAccess makes the changes, in one elevated step: optionally mark the
# network Private, add EmberStorm's Allow rule for Port on Private networks,
# and take Private out of any Docker Block rule (leaving it blocking on Public,
# where it was). Returns the exit code, or $null when permission was refused.
#
# The script is passed encoded, and everything put into it is an integer or a
# fixed string, so nothing from the network reaches it as code.
function Enable-LanAccess([int]$Port, [int]$InterfaceIndex, [bool]$MakePrivate) {
    $makePrivateText = if ($MakePrivate) { '$true' } else { '$false' }
    $script = @"
`$ErrorActionPreference = 'Stop'
# Modules from Windows' own folder only: run as administrator, this must not
# load one planted in the person's Documents (the security review).
`$env:PSModulePath = "`$PSHOME\Modules"
try {
    if ($makePrivateText) { Set-NetConnectionProfile -InterfaceIndex $InterfaceIndex -NetworkCategory Private }
    Get-NetFirewallRule -DisplayName '$($script:LanRuleName)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName '$($script:LanRuleName)' ``
        -Description 'Lets phones, TVs and other computers on a network you have marked Private reach EmberStorm. Added by the EmberStorm setup.' ``
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private | Out-Null
    `$blocks = Get-NetFirewallApplicationFilter | Where-Object { `$_.Program -like '*\com.docker.backend.exe' } |
        Get-NetFirewallRule | Where-Object {
            "`$(`$_.Direction)" -eq 'Inbound' -and "`$(`$_.Action)" -eq 'Block' -and
            "`$(`$_.Enabled)" -eq 'True' -and "`$(`$_.Profile)" -match 'Private|Any' }
    foreach (`$rule in `$blocks) {
        `$profiles = "`$(`$rule.Profile)"
        `$keep = @()
        if (`$profiles -match 'Any|Domain') { `$keep += 'Domain' }
        if (`$profiles -match 'Any|Public') { `$keep += 'Public' }
        if (`$keep.Count) { Set-NetFirewallRule -Name `$rule.Name -Profile (`$keep -join ',') } else { Disable-NetFirewallRule -Name `$rule.Name }
    }
    # Docker's backend given its answer before it first listens, so Windows
    # shows no "allow Docker Desktop Backend?" alert: allowed on Private,
    # blocked on Public - what the alert's own default would have made.
    try {
        # Where Docker Desktop puts it - named even before Docker is installed,
        # which a rule may be; anywhere else, looked for.
        `$pf = [Environment]::GetFolderPath('ProgramFiles')
        `$backend = Get-Item -LiteralPath (Join-Path `$pf 'Docker\Docker\resources\com.docker.backend.exe') -ErrorAction SilentlyContinue
        if (-not `$backend) { `$backend = Get-ChildItem -Path (Join-Path `$pf 'Docker') -Recurse -Filter 'com.docker.backend.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not `$backend) { `$backend = [pscustomobject]@{ FullName = (Join-Path `$pf 'Docker\Docker\resources\com.docker.backend.exe') } }
        if (`$backend) {
            Get-NetFirewallRule -DisplayName '$($script:DockerRuleName)*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            # Private only, and EmberStorm's port only: the backend answers
            # every port Docker publishes, and a work laptop's domain network
            # is not this setup's to open (the security reviews).
            New-NetFirewallRule -DisplayName '$($script:DockerRuleName) (private)' -Direction Inbound -Action Allow ``
                -Program `$backend.FullName -Protocol TCP -LocalPort $Port -Profile Private | Out-Null
            New-NetFirewallRule -DisplayName '$($script:DockerRuleName) (other networks)' -Direction Inbound -Action Block ``
                -Program `$backend.FullName -Protocol TCP -LocalPort $Port -Profile Public,Domain | Out-Null
        }
    } catch { }
    exit 0
} catch {
    exit 1
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    return Invoke-Elevated (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
}

# Set-LanAccess checks, asks where it has to, fixes, and reports how it went:
# 'ready', 'public' (said it is not a home network), 'domain', 'refused'
# (permission declined), 'failed', or 'unknown' (no LAN address to judge by).
function Set-LanAccess([string]$Address, [int]$Port) {
    if (-not $Address) { return 'unknown' }
    $network = Get-LanProfile $Address
    if (-not $network) { return 'unknown' }

    if ($network.Category -eq 'DomainAuthenticated') {
        Note "This PC is on a work network, so EmberStorm does not open itself to other"
        Note "devices on it - that is for whoever runs the network to decide."
        return 'domain'
    }

    $makePrivate = $false
    if ($network.Category -eq 'Public') {
        if (-not (Confirm-HomeNetwork $network.Name)) {
            Note "Leaving this network as it is."
            return 'public'
        }
        $makePrivate = $true
    } elseif (Test-LanAccessReady $Port) {
        Good "Other devices on your network can reach EmberStorm."
        return 'ready'
    }

    Note "Letting other devices on your home network reach EmberStorm."
    if (-not (Test-Administrator)) { Important "Windows will ask for permission - click Yes." }
    do {
        $code = Enable-LanAccess $Port $network.InterfaceIndex $makePrivate
    } while ($null -eq $code -and (Confirm-TryAgain 'let your other devices reach EmberStorm' -Optional))
    if ($null -eq $code) {
        Important "Permission was not given, so other devices still cannot reach it."
        return 'refused'
    }
    if ($code -eq 0 -and (Test-LanAccessReady $Port)) {
        Good "Done - other devices on your network can reach EmberStorm."
        return 'ready'
    }
    Important "Could not change the network settings (code $code)."
    return 'failed'
}

# Update-LanAddress points the recorded LAN address at this machine's current
# one when it has moved - a laptop on another network, or a router that handed
# out a new address. The secure name follows SOUNDSTORM_TLS_HOSTS, so without
# this it kept pointing at an address this PC no longer has. Only the first
# entry, and only when it has gone from every adapter here: an address still on
# this machine was chosen, not left behind. Returns $true when it changed.
function Update-LanAddress {
    $hosts = Get-EnvSetting 'SOUNDSTORM_TLS_HOSTS'
    if (-not $hosts) { return $false }
    $parts = @($hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $recorded = $null
    if (-not $parts -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$recorded)) { return $false }
    $current = Get-LanAddress
    if (-not $current -or $current -eq $parts[0]) { return $false }
    try {
        $mine = @(Get-NetIPAddress -ErrorAction Stop | ForEach-Object { $_.IPAddress })
    } catch {
        return $false
    }
    if ($mine -contains $parts[0]) { return $false }
    $parts[0] = $current
    Set-EnvSetting 'SOUNDSTORM_TLS_HOSTS' ($parts -join ',')
    return $true
}

# Confirm-LanOnLaunch asks the setup's question again when EmberStorm starts
# on a network Windows treats as public - every new Wi-Fi network is, unless
# somebody said otherwise - where phones and TVs cannot reach it and nothing
# said why: a laptop taken to another house, or a new router. Yes makes it
# private and opens the port, as the setup does (Windows asks for permission);
# No is remembered for that network's name, so it is asked once per network.
# A work network is left alone, as at setup.
# Set-LanAccessRemembered is Set-LanAccess, not asking again on a network
# somebody already said is not their home one - every update asked again.
function Set-LanAccessRemembered([string]$Lan, [int]$Port) {
    if (-not $Lan) { return 'unknown' }
    $network = Get-LanProfile $Lan
    $declined = @((Get-EnvSetting 'SOUNDSTORM_NOT_HOME') -split '\|' | Where-Object { $_ })
    # Compared as it is kept: "Bob's WiFi" is kept as "Bob s WiFi" (the blind
    # review: such a name was asked about at every update).
    $clean = if ($network -and $network.Name) { $network.Name -replace '[|\r\n#"''`]', ' ' } else { '' }
    if ($network -and $network.Category -eq 'Public' -and $clean -and $declined -contains $clean) { return 'public' }
    $result = Set-LanAccess $Lan $Port
    if ($result -eq 'public' -and $clean) {
        if (Test-Path -LiteralPath (Join-Path $Dir '.env')) {
            Set-EnvSetting 'SOUNDSTORM_NOT_HOME' ((@($declined + $clean) | Select-Object -Last 20) -join '|')
        } else {
            # A first install has no settings file yet: written once it has.
            $script:PendingNotHome = $clean
        }
    }
    return $result
}

function Confirm-LanOnLaunch {
    $lan = Get-LanAddress
    if (-not $lan) { return }
    $network = Get-LanProfile $lan
    if (-not $network -or $network.Category -ne 'Public' -or -not $network.Name) { return }
    $declined = @((Get-EnvSetting 'SOUNDSTORM_NOT_HOME') -split '\|' | Where-Object { $_ })
    $clean = $network.Name -replace '[|\r\n#"''`]', ' '
    if ($declined -contains $clean) { return }
    $result = Set-LanAccess $lan ([int](Get-InstalledPort))
    if ($result -eq 'public') {
        $names = @($declined) + @($clean)
        Set-EnvSetting 'SOUNDSTORM_NOT_HOME' ((@($names) | Select-Object -Last 20) -join '|')
    }
}

# Update-RouterSettings keeps the router's address and UPnP URL in .env
# current. They used to be written only when missing, so a laptop that moved
# kept asking the old house's router to open its port, and a replaced router
# was never found - the same stale-value bug the LAN address had. Returns $true
# when anything changed.
#
# The gateway is only replaced when it is no longer a route this machine has,
# so a value somebody set by hand stands for as long as it means anything. The
# UPnP URL is dropped when it points at a router that is no longer the gateway,
# and looked for again. -Quick (the desktop icon) only searches for it when the
# gateway changed: the search waits three seconds for answers, and the server
# can now find the router's UPnP by asking it directly anyway.
function Update-RouterSettings([switch]$Quick) {
    $changed = $false
    $stored = Get-EnvSetting 'SOUNDSTORM_GATEWAY'
    $hops = @()
    try {
        $hops = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object { $_.NextHop } | Where-Object { $_ -and $_ -ne '0.0.0.0' })
    } catch {
    }
    if (-not $stored -or ($hops.Count -gt 0 -and $hops -notcontains $stored)) {
        $gateway = Get-Gateway
        if ($gateway -and $gateway -ne $stored) {
            Set-EnvSetting 'SOUNDSTORM_GATEWAY' $gateway
            $changed = $true
        }
    }

    $url = Get-EnvSetting 'SOUNDSTORM_UPNP_URL'
    $gatewayNow = Get-EnvSetting 'SOUNDSTORM_GATEWAY'
    if ($url -and $gatewayNow) {
        $urlHost = ''
        try { $urlHost = ([Uri]$url).Host } catch { }
        if ($urlHost -ne $gatewayNow) {
            Set-EnvSetting 'SOUNDSTORM_UPNP_URL' ''
            $url = ''
            $changed = $true
        }
    }
    if (-not $url -and (-not $Quick -or $changed)) {
        $found = Get-UpnpUrl
        if ($found) {
            Set-EnvSetting 'SOUNDSTORM_UPNP_URL' $found
            $changed = $true
        }
    }
    return $changed
}

# Show-LanAdvice ends the summary with what to do if a phone still cannot
# connect. This PC can check its own settings but cannot see what the phone
# sees, so it says what is left to check rather than claiming it works.
function Show-LanAdvice([string]$State) {
    switch ($State) {
        'ready' {
            Write-Host "  If a phone still cannot connect: it must be on the same Wi-Fi as" -ForegroundColor Gray
            Write-Host "  this PC - not mobile data, and not a 'guest' network, which keeps" -ForegroundColor Gray
            Write-Host "  devices apart on purpose." -ForegroundColor Gray
            Write-Host ""
        }
        { $_ -in 'public', 'refused', 'failed' } {
            Important "Other devices cannot reach EmberStorm yet."
            Write-Host "  To fix it later, on your home network: in Windows Settings, open" -ForegroundColor Gray
            Write-Host "  Network & internet, your network, and set 'Network profile type' to" -ForegroundColor Gray
            Write-Host "  Private. Then open EmberStorm from its desktop icon." -ForegroundColor Gray
            Write-Host ""
        }
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Refresh-Path picks up what an installer just added.
#
# winget does not update the PATH of the session that called it, so `docker`
# stays unresolvable until a new window is opened - which looks exactly like
# the install having failed.
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

# Install-Docker uses winget, which ships with Windows 10 1809 and later.
#
# The alternative is telling somebody to visit a website, pick the right
# download and run an installer, which is the single step this script exists
# to remove.
#
# Docker Desktop's installer needs administrator rights, and a setup file run
# by double-clicking does not have them - so this step asks for them, once,
# with a UAC prompt. Without that winget fails and the whole install stops on
# its very first action.
# Invoke-Elevated runs one command as administrator.
#
# Returns its exit code, or $null when the prompt was refused or never
# appeared - which is a different failure from the command running and
# failing, and gets a different message.
# Get-WslPath is wsl.exe by its full path. Elevated programs are started by
# path, never by name: a name is looked up in the folder the setup runs in
# and on a PATH the user can change, so a planted wsl.exe would be what
# Windows asks permission for. Sysnative, from a 32-bit PowerShell, where
# System32 is redirected to a folder without it.
function Get-WslPath {
    $native = Join-Path ([Environment]::GetFolderPath('Windows')) 'Sysnative\wsl.exe'
    if (Test-Path $native) { return $native }
    return (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\wsl.exe')
}

function Invoke-Elevated([string]$File, [string[]]$Arguments) {
    if (Test-Administrator) {
        return (Invoke-Native $File $Arguments -Show).ExitCode
    }
    try {
        # Hidden: the setup window says what is happening, and a console
        # behind it is only something to wonder about.
        $process = Start-Process -FilePath $File -ArgumentList $Arguments `
            -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        # Waited on here rather than with -Wait, which would freeze the setup
        # window for as long as the command runs.
        $null = Wait-ProcessPumped $process
        return $process.ExitCode
    } catch {
        return $null
    }
}

# Test-WSL reports whether Windows Subsystem for Linux is there and modern
# enough for Docker's engine to run on.
#
# wsl.exe ships in System32 on every Windows 10 and 11 whether or not WSL is
# actually installed, so finding the command proves nothing. `--version` is
# the question that answers only where the real thing is present, and its exit
# code is the whole answer - the text it prints is UTF-16 and arrives full of
# null bytes through a pipe.
function Test-WSL {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    return ((Invoke-Native 'wsl.exe' @('--version')).ExitCode -eq 0)
}

# Install-WSL is the second thing a new PC needs, and the second thing nobody
# is told about until Docker refuses to start.
#
# Docker Desktop runs its engine inside WSL2. On a machine that has never had
# it, Docker installs happily, launches, and then puts up a dialog asking for
# WSL to be installed or updated - a command the user now has to find, run as
# administrator, and follow with a restart. That is three steps past where an
# installer should have stopped asking, and it is where the first person to
# use this got stuck after the BIOS.
# Test-RestartPending says whether Windows is waiting on a restart to finish
# installing something - the marks Windows' own servicing leaves.
function Test-RestartPending {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    return $false
}

function Install-WSL {
    if (Test-WSL) { return }

    Note "Setting up Windows Subsystem for Linux, which Docker runs on. This takes a few minutes."
    if (-not (Test-Administrator)) {
        Important "Windows will ask for permission - click Yes."
    }

    # --no-distribution because Docker brings its own. Without it Windows also
    # fetches Ubuntu: a gigabyte, several more minutes, and a first-run prompt
    # asking for a Linux username that nobody here will ever use again.
    do {
        $code = Invoke-Elevated (Get-WslPath) @('--install', '--no-distribution')
    } while ($null -eq $code -and (Confirm-TryAgain 'install Windows Subsystem for Linux'))

    if ($null -eq $code) {
        Stop-With @"
  Installing Windows Subsystem for Linux needs permission, and that was
  refused or dismissed. Docker cannot run without it.

  Run this setup again and choose Yes when Windows asks.
"@
    }

    if ($code -ne 0) {
        # A Windows too old to know --no-distribution, or a WSL that is
        # present but stale and wants updating rather than installing.
        $null = Invoke-Elevated (Get-WslPath) @('--update')
    }

    Refresh-Path
    if (Test-WSL) {
        # Installed, but switched on only at the next start: WSL answers
        # already, and Docker's engine then never came up (a review). Docker
        # is installed first, so one restart finishes both.
        if (Test-RestartPending) { $script:RestartAfterDocker = $true }
        Good "Windows Subsystem for Linux is ready."
        return
    }

    Stop-ForRestart @"
  Windows Subsystem for Linux has to be there before Docker can run, and it
  is not finished yet.

  This nearly always just needs a restart: Restart now, below. The setup
  picks up where it left off, and nothing already downloaded is lost.

  If it stops here a second time, switch it on by hand:

    1. Open the Start menu and type:  Turn Windows features on or off
    2. Tick "Windows Subsystem for Linux" and "Virtual Machine Platform".
    3. Click OK, restart the PC, and run this setup again.
"@
}

function Install-Docker {
    # Docker's own installer, straight from Docker and checked as signed by
    # Docker, always: winget ran as administrator from the person's own
    # folder (which their programs can change), and on a standard account its
    # per-user copy would not start under an administrator's password - shown
    # as "permission refused" (the blind review). The winget path below stays
    # only for a later decision.
    Install-DockerDirect
    return

    Note "Getting Docker Desktop - a big download that takes a few minutes."
    # Installed with its terms accepted and its questions answered, so its
    # first start asks nothing (Show-DockerGuide says so, and what the terms
    # are).
    $script:dockerInstalledNow = $true
    Show-DockerGuide -FirstRun

    # Written before the install as well as after it. Docker Desktop launches
    # itself the moment its installer finishes, which is too early for anything
    # this script does afterwards to prevent - but it reads this file on that
    # first launch, so putting the setting there first is the only way to stop
    # the window ever appearing.
    Hide-DockerDashboard -Quiet

    # --override hands Docker's installer exactly these: quiet, and its
    # terms accepted (its own switch for an unattended install), which is
    # what keeps its first start from asking.
    $wingetArgs = @(
        'install', '--exact', '--id', 'Docker.DockerDesktop',
        '--accept-source-agreements', '--accept-package-agreements', '--silent',
        '--override', 'install --quiet --accept-license'
    )

    $code = Invoke-WingetDocker $wingetArgs
    Refresh-Path
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        # Should Docker's installer ever refuse those switches, it is tried
        # once more the ordinary way - and its first start will then ask for
        # its terms, which the setup says before starting it.
        Note "Trying the Docker install once more, the ordinary way."
        $script:dockerInstalledNow = $false
        $script:dockerGuideShown = $false
        $code = Invoke-WingetDocker ($wingetArgs | Select-Object -First 7)
        Refresh-Path
    }

    # Whether it worked is better answered by looking than by decoding an exit
    # code. winget has a family of them - 0 is installed, 0x8A150061 is already
    # installed, and a reboot-required result is a success that reads like a
    # failure - so the question asked here is simply whether docker is there
    # now.
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Good "Docker Desktop installed."
        Save-SetupChange 'docker' $true
        Hide-DockerDashboard
        Grant-DockerUse
        return
    }
    # winget could not (on a standard account, an administrator's permission
    # runs it where it is often not set up): Docker's own installer, straight
    # from Docker, which does not depend on it (a review).
    Note "winget could not install it - getting it straight from Docker instead."
    Install-DockerDirect
}

# Install-DockerDirect fetches Docker Desktop's installer from Docker itself
# and runs it as administrator, quiet and with its terms accepted - the same
# switches winget hands it.
# Test-AdminAccount says whether this person's account is an administrator,
# elevated or not: an ordinary token lists Administrators only as deny-only,
# which WindowsIdentity.Groups leaves out (the blind review: every home admin
# was taken for a standard account).
function Test-AdminAccount {
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent()
        return [bool](@($me.Claims | Where-Object { $_.Value -eq 'S-1-5-32-544' }).Count)
    } catch {
        return $true
    }
}

# Grant-DockerUse adds this person to Docker's docker-users group when somebody
# else's administrator password installed it: Docker adds the account that ran
# its installer, so on a standard account Docker refused this person and its
# engine never answered, restart after restart (the bug review). The group
# counts from the next sign-in, so a restart is asked for.
function Grant-DockerUse {
    try {
        if (Test-AdminAccount) { return }
        $sid = "$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
        if ($sid -notmatch '^S-1-5-21-[0-9-]+$') { return }
    } catch { return }
    Note "Letting your account use Docker (it joins Docker's users, who can run anything in Docker) - Windows will ask for permission."
    $grant = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$env:PSModulePath = "`$PSHOME\Modules"
Add-LocalGroupMember -Group 'docker-users' -Member '$sid'
exit 0
"@
    $null = Invoke-Elevated (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($grant)))
    $script:RestartAfterDocker = $true
}

function Install-DockerDirect {
    Note "Getting Docker Desktop from Docker - a big download that takes a few minutes."
    $script:dockerInstalledNow = $true
    Show-DockerGuide -FirstRun
    Hide-DockerDashboard -Quiet
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $url = "https://desktop.docker.com/win/main/$arch/Docker%20Desktop%20Installer.exe"
    $installer = Join-Path $env:TEMP 'EmberStorm-Docker-Installer.exe'
    $curl = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\curl.exe'
    # Its size first, for "310 of 635 MB" as it comes.
    $size = 0
    try {
        $head = & $curl -sIL $url 2>$null
        $last = @($head | Where-Object { $_ -match '^content-length:\s*(\d+)' }) | Select-Object -Last 1
        if ($last -match '(\d+)') { $size = [long]$Matches[1] }
    } catch { }
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    # https only, redirects included: a redirect down to http would have
    # handed over whatever answered (the security review).
    $download = Start-Process -FilePath $curl -ArgumentList '-fsSL', '--proto', '=https', '--proto-redir', '=https', '--retry', '3', '-o', "`"$installer`"", $url `
        -WindowStyle Hidden -PassThru
    $null = $download.Handle
    $shown = Get-Date
    while (-not $download.WaitForExit(250)) {
        Update-Gui
        if (((Get-Date) - $shown).TotalSeconds -ge 1) {
            $shown = Get-Date
            $got = 0
            try { $got = (Get-Item -LiteralPath $installer -ErrorAction Stop).Length } catch { }
            if ($size -gt 0) {
                Set-GuiStatus "Downloading Docker Desktop: $([int]($got / 1MB)) of $([int]($size / 1MB)) MB"
                Set-GuiStepProgress (0.15 + 0.45 * ($got / $size))
            } else {
                Set-GuiStatus "Downloading Docker Desktop: $([int]($got / 1MB)) MB so far"
            }
        }
    }
    Note "Installing Docker Desktop. This takes a few minutes."
    if ($download.ExitCode -ne 0 -or -not (Test-Path $installer) -or (Get-Item $installer).Length -lt 10MB) {
        Stop-With @"
  Docker Desktop could not be downloaded (curl exit code: $($download.ExitCode)).

  Check the internet connection and run the setup again - or install
  Docker Desktop yourself from here and then run the setup again:

    https://www.docker.com/products/docker-desktop/
"@
    }
    # Signed by Docker, or not run: checked here first, then again as
    # administrator on a copy in a folder only administrators can change, the
    # copy run from there - so nothing can swap the file between the check
    # and the run (the security review).
    Set-GuiStatus "Checking Docker Desktop's installer is really Docker's..."
    $sig = @(Invoke-Pumped { param($file) Get-AuthenticodeSignature -LiteralPath $file } @($installer))[-1]
    if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch '(^|, )O=Docker Inc,') {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        Stop-With @"
  The Docker Desktop installer that was downloaded is not signed by Docker,
  so it was not run.

  Run the setup again - or install Docker Desktop yourself from here and
  then run the setup again:

    https://www.docker.com/products/docker-desktop/
"@
    }
    Important "Windows will ask for permission to install it - click Yes."
    $source = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($installer)
    $dataRootArg = ''
    $dataRoot = Get-DockerDataRoot
    if ($dataRoot) {
        # Made at a drive's root, it would take the drive's permissions, which
        # let other accounts on the PC in: it holds EmberStorm's accounts and
        # the media servers' databases, so it is this person's alone - and
        # never a folder somebody else made there first.
        if ((Test-Path -LiteralPath $dataRoot) -and -not (Test-OwnedByMe $dataRoot)) {
            Stop-With @"
  A folder called $dataRoot is already there and belongs to another
  account on this PC, so EmberStorm's own data was not put in it.

  Remove or rename that folder, then run the setup again.
"@
        }
        New-Item -ItemType Directory -Force -Path $dataRoot -ErrorAction SilentlyContinue | Out-Null
        $null = Protect-PrivateFolder $dataRoot
        Save-SetupChange 'dockerData' $dataRoot
        $dataRootArg = ", '--wsl-default-data-root=$([Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($dataRoot))'"
        Note "Docker's downloads and data will be kept in $dataRoot."
    }
    $elevated = @"
`$ErrorActionPreference = 'Stop'
`$env:PSModulePath = "`$PSHOME\Modules"
try {
    `$dir = Join-Path ([Environment]::GetFolderPath('Windows')) ('Temp\EmberStorm-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path `$dir | Out-Null
    `$acl = New-Object Security.AccessControl.DirectorySecurity
    `$acl.SetAccessRuleProtection(`$true, `$false)
    foreach (`$who in 'S-1-5-18', 'S-1-5-32-544') {
        `$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (New-Object Security.Principal.SecurityIdentifier `$who), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    (Get-Item -LiteralPath `$dir).SetAccessControl(`$acl)
    `$exe = Join-Path `$dir 'DockerDesktopInstaller.exe'
    Copy-Item -LiteralPath '$source' -Destination `$exe
    `$sig = Get-AuthenticodeSignature -LiteralPath `$exe
    if (`$sig.Status -ne 'Valid' -or "`$(`$sig.SignerCertificate.Subject)" -notmatch '(^|, )O=Docker Inc,') { exit 77 }
    `$p = Start-Process -FilePath `$exe -ArgumentList 'install', '--quiet', '--accept-license'$dataRootArg -PassThru
    `$p.WaitForExit()
    Remove-Item -LiteralPath `$dir -Recurse -Force -ErrorAction SilentlyContinue
    exit `$p.ExitCode
} catch {
    exit 78
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevated))
    $powershellExe = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    do {
        $code = Invoke-Elevated $powershellExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    } while ($null -eq $code -and (Confirm-TryAgain 'install Docker Desktop'))
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if ($null -eq $code) {
        Stop-With @"
  Installing Docker Desktop needs permission, and that was refused or
  canceled.

  Run the setup again and choose Yes when Windows asks.
"@
    }
    if ($code -eq 77) {
        Stop-With "  The Docker Desktop installer was not signed by Docker, so it was not run.`n`n  Run the setup again."
    }
    Refresh-Path
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Good "Docker Desktop installed."
        Save-SetupChange 'docker' $true
        Hide-DockerDashboard
        Grant-DockerUse
        return
    }
    Stop-ForDockerInstall $code
}

# Invoke-WingetDocker runs winget with these arguments, elevated when the setup
# is not, and answers its exit code.
function Invoke-WingetDocker([string[]]$wingetArgs) {
    if (Test-Administrator) {
        return (Invoke-Native 'winget' $wingetArgs -Show).ExitCode
    } else {
        Important "Windows will ask for permission to install it - click Yes."
        try {
            # By its real place, not its name: a name is looked up through
            # PATH, which this user's programs can change, and this runs as
            # administrator (a security review).
            $winget = (Get-Command winget -ErrorAction Stop).Source
            $apps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
            if (-not $winget.StartsWith($apps, [StringComparison]::OrdinalIgnoreCase) -and
                -not $winget.StartsWith($env:ProgramFiles, [StringComparison]::OrdinalIgnoreCase)) {
                throw "winget is in an unexpected place: $winget"
            }
            # Start-Process joins its arguments with spaces and quotes none,
            # so the one with spaces in it (--override's) is quoted here; the
            # call above quotes it itself.
            $quoted = $wingetArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
            $process = $null
            do {
                try {
                    $process = Start-Process -FilePath $winget -ArgumentList $quoted `
                        -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
                } catch {
                    $process = $null
                }
            } while (-not $process -and (Confirm-TryAgain 'install Docker Desktop'))
            if (-not $process) { throw 'permission refused' }
            # Waited on here rather than with -Wait, which would freeze the
            # setup window for the minutes Docker Desktop takes to install.
            $null = Wait-ProcessPumped $process
            return $process.ExitCode
        } catch {
            Stop-With @"
  Installing Docker Desktop needs permission, and that was refused or
  canceled.

  Run the setup again and choose Yes when Windows asks - or install Docker
  Desktop yourself from here and then run the setup again:

    https://www.docker.com/products/docker-desktop/
"@
        }
    }
}

function Stop-ForDockerInstall($code) {
    Stop-ForRestart @"
  Docker Desktop did not finish installing. (exit code: $code)

  This is usually one of two things:

    * it needs a restart to finish - Restart now, below
    * Windows features for virtualization are off - Docker Desktop will say
      so if you open it from the Start menu

  Or install it yourself from here and run the setup again:

    https://www.docker.com/products/docker-desktop/
"@
}

# Test-Virtualization answers whether this PC can run Docker at all.
#
# Docker on Windows runs Linux in a lightweight virtual machine, so hardware
# virtualization is not optional. Essentially every CPU since 2008 has it and
# a great many prebuilt desktops ship with it switched off in the firmware,
# which is a thing only a trip into the BIOS can change.
#
# Asked before the download rather than after, because the alternative is what
# happened to the first person who ran this: 500MB of Docker Desktop
# installed, and only then "virtualization support wasn't detected" - leaving
# a program they cannot use, on a machine they now have to go and fix anyway,
# with nothing on screen explaining which of those two things went wrong.
#
# True when it cannot tell. Refusing to install on a machine that is actually
# fine is a worse failure than the check never firing, and this is a guess
# about firmware read through two layers of Windows.
function Test-Virtualization {
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    } catch {
        return $true
    }
    if (-not $system) { return $true }

    # A running hypervisor settles it: Hyper-V or WSL2 is already up, and
    # neither can be without virtualization. This has to be asked first,
    # because once a hypervisor is present Windows reports
    # VirtualizationFirmwareEnabled as false regardless - it can no longer see
    # the firmware to ask. Checking the other property first would read a
    # perfectly working PC as a broken one.
    if ($system.HypervisorPresent) { return $true }

    # Explicitly false, not merely missing. An older Windows may not populate
    # this at all, and absent means unknown rather than off.
    $property = $system.PSObject.Properties['VirtualizationFirmwareEnabled']
    if ($property -and $system.VirtualizationFirmwareEnabled -eq $false) {
        return $false
    }
    return $true
}

# The one failure this script cannot work around, so it gets the whole recipe
# rather than a line saying to go and look it up.
function Stop-ForVirtualization {
    $text = @"
  This PC has hardware virtualization turned off, and Docker cannot run
  without it. Nothing has been installed.

  It is switched off rather than missing, on almost every PC this happens
  to, and turning it on means a trip into the BIOS:

    1. Restart the PC and press the setup key as it starts - usually Del or
       F2. (Dell: F2.  HP: F10.  Lenovo: F1.)
    2. Find "Intel Virtualization Technology", "Intel VT-x", or on an AMD
       machine "SVM Mode". It is usually under Advanced, CPU Configuration
       or Security.
    3. Set it to Enabled, then Save and Exit.
    4. Run this setup again.

  To check it worked: Ctrl+Shift+Esc, the Performance tab, click CPU, and
  read the Virtualization line on the right.
"@
    # The steps kept where they can be read again: they are gone from the
    # screen the moment the PC restarts into its BIOS.
    $saved = ''
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $file = Join-Path $desktop 'EmberStorm - turn on virtualization.txt'
        [IO.File]::WriteAllText($file, ($text -replace "`r?`n", "`r`n"))
        $saved = "`n`n  These steps are saved on your desktop too, to read again."
    } catch { }
    $resume = if (Register-Resume) {
        "`n  Once it is on, sign in again and the setup carries on by itself."
    } else { '' }
    $intro = "`n`n  Restart into BIOS setup, below, takes this PC straight into its setup"
    $intro += "`n  screen on most PCs - then follow steps 2 and 3."
    Stop-With ($text + $intro + $saved + $resume) @{
        Label = 'Restart into BIOS setup'
        Run   = {
            try {
                # /fw restarts into the firmware's own setup screen; it needs
                # administrator, so Windows asks.
                Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\shutdown.exe') `
                    -ArgumentList '/r', '/fw', '/t', '0' -Verb RunAs -WindowStyle Hidden -ErrorAction Stop
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "This PC could not be restarted straight into its setup screen. Restart it yourself and press the setup key as it starts - usually Del or F2.",
                    'EmberStorm') | Out-Null
            }
        }
    }
}

# Start-Docker launches Docker Desktop and waits for its engine.
#
# "Docker is installed but not running" is the most common failure on Windows
# by a distance, and the old answer - go and open it yourself - is exactly the
# kind of instruction this is trying not to give.
function Start-Docker([switch]$NoStop) {
    $exe = Get-DockerDesktopPath
    if (-not $exe) {
        if ($NoStop) { return $false }
        Stop-With @"
  Docker Desktop is installed but this script cannot find it to start it.

  Open Docker Desktop from the Start menu, wait until it says Running, then
  run this again.
"@
    }

    # Before a Docker's first start only (one installed some other way, never
    # opened): its dashboard kept away and its sign-in and questions marked
    # done. A Docker somebody has used keeps whatever they chose in it.
    $firstRun = Test-DockerFirstRun
    if ($firstRun) { Hide-DockerDashboard -Quiet }
    if (-not $NoStop) { Show-DockerGuide -FirstRun:$firstRun }
    Note "Starting Docker Desktop. This takes a minute or two."
    Start-Process -FilePath $exe | Out-Null

    $waited = 0
    while (-not (Test-DockerRunning)) {
        Start-Sleep -Seconds 3
        $waited += 3
        if ($waited % 30 -eq 0) {
            Note "Docker is still starting... ($waited seconds). This is normal."
            # By a minute in, a window waiting on a click is the likeliest
            # reason, and the box that said what to click has scrolled away.
            if ($waited -eq 60) {
                Important "If a Docker window is open, it may be waiting on you: accept its terms, and Skip anything else."
            }
        }
        if ($waited -gt 420) {
            # Uninstalling: carry on without it rather than stop (a catch
            # cannot stop an exit, and the uninstall ended part way).
            if ($NoStop) { return $false }
            # Docker was already installed when this run started, so the
            # check above never ran. It is worth asking now: an engine that
            # never comes up is exactly what a firmware setting being off
            # looks like from here.
            if (-not (Test-Virtualization)) { Stop-ForVirtualization }
            # Installed in this run: a restart is what it nearly always wants.
            if ($script:dockerInstalledNow -or (Test-RestartPending)) {
                Stop-ForRestart @"
  Docker Desktop is installed, but its engine has not started yet. A fresh
  install nearly always needs one restart: Restart now, below.
"@
            }
            Stop-With @"
  Docker Desktop was started but its engine never came up.

  On a brand new install it usually wants one of these first:

    * its terms accepted - open Docker Desktop from the Start menu and
      see whether it is waiting on a window
    * Windows Subsystem for Linux - if Docker is asking you to install or
      update WSL, run this setup again and it will do it for you
    * a restart of the PC

  Do whichever it asks for, then run this setup again. Nothing is lost -
  it picks up where it left off.
"@
        }
    }
    Good "Docker is running."
    if ($NoStop) { return $true }
}

function Initialize-Docker {
    $installed = [bool](Get-Command docker -ErrorAction SilentlyContinue)
    # WSL greets its first start with a "Welcome to Windows Subsystem for
    # Linux" window, which on the test box popped up over the setup when
    # Docker first started it - something else to wonder about. It is shown
    # only while this person's OOBEComplete is unset (read by wslservice), so
    # it is set first, never changed once there.
    try {
        $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if ($null -eq (Get-ItemProperty -Path $lxss -Name 'OOBEComplete' -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path $lxss)) { New-Item -Path $lxss -Force | Out-Null }
            New-ItemProperty -Path $lxss -Name 'OOBEComplete' -Value 1 -PropertyType DWord -Force | Out-Null
        }
    } catch { }

    # Only where somebody is sitting in front of it. The desktop shortcut runs
    # this minimized at startup, and a permission prompt with no visible
    # window behind it is worse than the failure it would be fixing.
    if (-not $Launch) {
        # Before the download, not after. Docker Desktop is half a gigabyte
        # and installing it on a machine that cannot run it helps nobody.
        if (-not $installed -and -not (Test-Virtualization)) { Stop-ForVirtualization }
        # And before Docker rather than after, because Docker's installer
        # assumes WSL is already there. Checked even when Docker is present:
        # "installed but will not start" is most often a stale WSL, which is
        # exactly what Docker's own dialog asks you to go and fix by hand.
        Install-WSL
    }

    if (-not $installed) {
        # Not from the desktop icon or at sign-in: a permission prompt behind a
        # minimized window (a review).
        if ($Launch) { Stop-With "  Docker Desktop is not installed. Run the EmberStorm setup again to put it back." }
        Install-Docker
    }
    Refresh-Path
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-ForRestart @"
  Docker Desktop is installed but Windows has not picked it up in this
  window yet.

  A fresh Docker install usually wants a restart anyway: Restart now, below.
"@
    }
    if ($script:RestartAfterDocker -and -not (Test-DockerRunning)) {
        Stop-ForRestart @"
  Windows Subsystem for Linux and Docker Desktop are installed. Windows needs
  one restart to finish switching them on: Restart now, below.
"@
    }
    if (-not (Test-DockerRunning)) { Start-Docker }
}

# Test-PortFree binds the port rather than listing connections: a listener with
# no connection to it does not show up in Get-NetTCPConnection on every Windows
# build, and binding is the question we actually care about.
# Get-ExistingInstallPath reads where an existing install was launched from.
#
# Through ConvertFrom-Json rather than a --format template, because PowerShell
# strips the inner double quotes out of
# '{{index .Config.Labels "com.docker.compose..."}}' on the way to docker, and
# docker then fails with `function "com" not defined`. That is invisible until
# the script is actually run on Windows.
function Get-ExistingInstallPath {
    $found = ''
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = docker inspect soundstorm 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $labels = ($raw | ConvertFrom-Json)[0].Config.Labels
            if ($labels) {
                $found = $labels.'com.docker.compose.project.working_dir'
            }
        }
    } catch {
        $found = ''
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if (-not $found) { return '' }
    return $found
}

function Test-PortFree([int]$Port) {
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch {} }
    }
}

# Test-Healthz asks once and answers true or false.
#
# HttpWebRequest rather than Invoke-WebRequest, and that is not a preference.
# PowerShell 5.1 has no -SkipCertificateCheck, so trusting our own self-signed
# certificate means assigning ServicePointManager.ServerCertificateValidationCallback
# - and with a scriptblock in that callback, Invoke-WebRequest fails against
# *every* https address, ours and github.com alike, with "An unexpected error
# occurred on a send". It runs the request off the pipeline thread, where there
# is no runspace to execute a scriptblock in, so the validation delegate throws
# and the connection is torn down. The error names the send, never the callback.
# HttpWebRequest.GetResponse() runs on the pipeline thread and is fine.
function Test-Healthz([string]$Url) {
    try {
        $request = [Net.HttpWebRequest]::Create("$Url/healthz")
        $request.Timeout = 5000
        $request.Method = 'GET'
        $response = $request.GetResponse()
        $response.Close()
        return $true
    } catch {
        return $false
    }
}

function Wait-ForEmberStorm([string]$Url) {
    # Process-wide, because .NET Framework offers no per-request hook. Set for
    # the few seconds of the health check and put back afterwards; the requests
    # it covers go to a certificate this machine minted, on this machine.
    $priorCallback = $null
    $bypassed = $false
    if ($Url -like 'https://*') {
        $priorCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $bypassed = $true
    }
    try {
        $waited = 0
        while (-not (Test-Healthz $Url)) {
            if ($waited -eq 0) { Note "Waiting for EmberStorm to answer - usually under a minute." }
            Start-Sleep -Seconds 2
            $waited += 2
            # Up to three minutes with nothing on screen is exactly when
            # somebody decides it has hung and closes the window.
            if ($waited % 20 -eq 0) { Note "still starting... ($waited seconds). This is normal the first time." }
            if ($waited -gt 180) {
                Save-EmberStormLog
                Stop-With "  EmberStorm started but never answered.`n`n$(Get-HelpAdvice)"
            }
        }
    } finally {
        if ($bypassed) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $priorCallback }
    }
}

# Takes the folder, because the one thing this has to read is sometimes
# somebody else's install: when the setup refuses because EmberStorm is
# already installed elsewhere, the useful half of that message is the address
# of the install it found.
function Get-EnvSettingIn([string]$Folder, [string]$Name) {
    $envFile = Join-Path $Folder '.env'
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in (Get-Content -Encoding UTF8 $envFile)) {
        # A $ is kept in .env as $$, which compose reads as one (Set-EnvSetting).
        if ($line -match "^\s*$([regex]::Escape($Name))=(.*)$") { return $Matches[1].Trim().Replace('$$', '$') }
    }
    return $null
}

function Get-EnvSetting([string]$Name) {
    return Get-EnvSettingIn $Dir $Name
}

# Get-LibraryPath is where this install keeps its media: the folder beside it,
# unless .env says otherwise. Read from .env every time, so the shortcuts, the
# folders and the uninstaller can never disagree about it.
function Get-LibraryPath {
    $chosen = Get-EnvSetting 'SOUNDSTORM_LIBRARY_PATH'
    if ($chosen) { return ($chosen -replace '/', '\') }
    return (Join-Path $Dir 'library')
}

# Format-Size is a byte count the way Explorer shows one.
function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    return ('{0:N0} GB' -f ($Bytes / 1GB))
}

# Get-LocalDrives is the drives a library can live on: fixed and removable
# ones with a letter. Network drives are left out on purpose - Docker Desktop
# cannot see a mapped drive letter, so offering one would be offering a library
# the media servers cannot read.
function Get-LocalDrives {
    try {
        return @(Get-CimInstance Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { ($_.DriveType -eq 2 -or $_.DriveType -eq 3) -and $_.Size -gt 0 })
    } catch {
        return @()
    }
}

# Resolve-LibraryChoice turns a folder somebody picked into the library folder,
# or no path and the reason when it cannot be one.
#
# A folder of its own inside whatever was picked: somebody who picks E:\ does
# not mean "scatter seven shelves across the root of my drive", and somebody who
# picks an existing Media folder does not mean "mix these in with what is
# there". A network location looks like any other folder in the picker, and the
# media servers cannot read one - Docker Desktop sees neither mapped drives nor
# \\server\share paths - so that is refused now rather than found later as an
# empty library.
function Resolve-LibraryChoice([string]$Picked) {
    if (-not $Picked -or -not $Picked.Trim()) { return @{ Path = $null; Problem = '' } }
    $Picked = $Picked.Trim().Trim('"')
    $isNetwork = $Picked.StartsWith('\\')
    if (-not $isNetwork -and $Picked -match '^([A-Za-z]:)') {
        try {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Matches[1].ToUpper())'" -ErrorAction Stop
            $isNetwork = ($disk.DriveType -eq 4)
        } catch {
        }
    }
    if ($isNetwork) {
        return @{ Path = $null; Problem = 'That is a network location, which EmberStorm cannot use. Choose a drive plugged into this PC.' }
    }
    if ([IO.Path]::GetFileName($Picked.TrimEnd('\')) -ne 'EmberStorm') {
        $Picked = Join-Path $Picked 'EmberStorm'
    }
    return @{ Path = $Picked; Problem = '' }
}

# New-TopmostOwner is an invisible window for a message box to belong to.
# Without an owner that is on top, a dialog opened from a console can appear
# *behind* the setup window - and a setup waiting on a window nobody can see
# looks exactly like one that has hung.
function New-TopmostOwner {
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.StartPosition = 'CenterScreen'
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $owner.Opacity = 0
    $owner.Show()
    $owner.Activate()
    return $owner
}

# Select-LibraryLocation asks where the media should go and returns the folder
# chosen, or $null to keep Default.
#
# -Library could always do this, but nothing ever asked, so only somebody who
# had read the README knew it was possible - and the library is the one part of
# this that outgrows a laptop's disk, where moving it later means moving every
# file.
#
# A window with buttons and Windows' own folder browser, not a question typed
# into the console: the people this is for are put off by a command prompt, and
# "type C to choose" is still a command prompt. The console question is only
# the fallback for a machine that cannot show a window.
function Select-LibraryLocation([string]$Default, [string]$Intro = '') {
    $drives = Get-LocalDrives
    # A small system drive beside a roomier one - a mini PC's built-in 64GB
    # and its big drive, say: the roomier one is shown, and taken if the
    # window is just closed. A film collection fills a small C: and then
    # Windows with it.
    $suggested = $false
    if (-not $Intro -and $Default -match '^([A-Za-z]:)') {
        $here = @($drives | Where-Object { $_.DeviceID -eq $Matches[1].ToUpper() }) | Select-Object -First 1
        $roomiest = @($drives | Where-Object { $_.DriveType -eq 3 } | Sort-Object FreeSpace -Descending) | Select-Object -First 1
        if ($here -and $roomiest -and $roomiest.DeviceID -ne $here.DeviceID -and
            $here.FreeSpace -lt 100GB -and $roomiest.FreeSpace -gt 2 * $here.FreeSpace -and $roomiest.FreeSpace -gt 100GB) {
            $Intro = "$($here.DeviceID) has only $(Format-Size $here.FreeSpace) free, so your music, films and books will be kept on $($roomiest.DeviceID), which has $(Format-Size $roomiest.FreeSpace):"
            $Default = Join-Path ($roomiest.DeviceID + '\') 'EmberStorm'
            $suggested = $true
        }
    }
    if ($script:Gui) { return (Select-LibraryInWindow $Default $Intro $drives $suggested) }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()
    } catch {
        return (Read-LibraryLocation $Default $drives)
    }

    Note "A window has opened asking where to keep your library."

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'EmberStorm - where should your library go?'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.ClientSize = New-Object System.Drawing.Size(560, 360)

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = if ($Intro) { $Intro } else { 'Your music, films and books will be kept in this folder:' }
    $heading.Location = New-Object System.Drawing.Point(20, 16)
    $heading.Size = New-Object System.Drawing.Size(520, 44)
    $form.Controls.Add($heading)

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.ReadOnly = $true
    $pathBox.Text = $Default
    $pathBox.Location = New-Object System.Drawing.Point(20, 62)
    $pathBox.Size = New-Object System.Drawing.Size(520, 28)
    $form.Controls.Add($pathBox)

    $lines = @('A film collection can need hundreds of GB. To keep it on another drive - an external one, say - choose a folder there now. Moving it later means moving every file.')
    if ($drives.Count -gt 1) {
        $lines += ''
        $lines += 'Free space:'
        # The roomiest eight: that is what the question turns on, and the box
        # has room for eight lines.
        foreach ($drive in @($drives | Sort-Object FreeSpace -Descending | Select-Object -First 8)) {
            $label = if ($drive.VolumeName) { " ($($drive.VolumeName))" } else { '' }
            $lines += "    $($drive.DeviceID)$label   $(Format-Size $drive.FreeSpace) free of $(Format-Size $drive.Size)"
        }
    }
    $space = New-Object System.Windows.Forms.Label
    $space.Text = $lines -join "`r`n"
    $space.Location = New-Object System.Drawing.Point(20, 102)
    $space.Size = New-Object System.Drawing.Size(520, 180)
    $space.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($space)

    $problem = New-Object System.Windows.Forms.Label
    $problem.ForeColor = [System.Drawing.Color]::Firebrick
    $problem.Location = New-Object System.Drawing.Point(20, 284)
    $problem.Size = New-Object System.Drawing.Size(520, 24)
    $form.Controls.Add($problem)

    $choose = New-Object System.Windows.Forms.Button
    $choose.Text = 'Choose a different folder...'
    $choose.Location = New-Object System.Drawing.Point(20, 314)
    $choose.Size = New-Object System.Drawing.Size(240, 34)
    $form.Controls.Add($choose)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Continue'
    $ok.Location = New-Object System.Drawing.Point(420, 314)
    $ok.Size = New-Object System.Drawing.Size(120, 34)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok
    # Focus on the button, not the path: a highlighted path reads as something
    # to edit, and the box is only there to be read.
    $form.ActiveControl = $ok

    $choose.Add_Click({
        $browser = New-Object System.Windows.Forms.FolderBrowserDialog
        $browser.Description = 'Choose where EmberStorm keeps your music, films and books. A folder called EmberStorm is made inside the one you pick.'
        $browser.ShowNewFolderButton = $true
        $browser.RootFolder = [Environment+SpecialFolder]::MyComputer
        if ($browser.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $resolved = Resolve-LibraryChoice $browser.SelectedPath
            if ($resolved.Path) {
                $pathBox.Text = $resolved.Path
                $problem.Text = ''
            } else {
                $problem.Text = $resolved.Problem
            }
        }
        $browser.Dispose()
    })

    Set-DarkTheme $form
    Set-PrimaryButton $ok
    $chosen = $Default
    try {
        # Closing the window with the X means "carry on with what it shows" -
        # the default, unless a folder was picked first.
        [void]$form.ShowDialog()
        $chosen = $pathBox.Text
    } finally {
        $form.Dispose()
    }
    if ($chosen -eq $Default -and -not $suggested) { return $null }
    return $chosen
}

# Select-LibraryInWindow is the library question as a page of the setup
# window: the folder, the drives' free space, a different folder chosen in
# Windows' own folder picker. The same answers as Select-LibraryLocation.
function Select-LibraryInWindow([string]$Default, [string]$Intro, $Drives, [bool]$Suggested) {
    $path = $Default
    $problem = ''
    while ($true) {
        $heading = if ($Intro) { $Intro } else { 'Your music, films and books will be kept here:' }
        $lines = @()
        $page = New-GuiPageText 'Where should your library go?' @($heading)
        $box = New-Object System.Windows.Controls.Border
        $box.CornerRadius = 9
        $box.Background = New-WpfBrush '#1E1E28'
        $box.BorderBrush = New-WpfBrush '#33334A'
        $box.BorderThickness = 1
        $box.Padding = '12,9'
        $box.Margin = '0,10,0,10'
        $box.Child = (New-GuiLine $path 15 '#FFFFFF' 'SemiBold')
        [void]$page.Children.Add($box)
        [void]$page.Children.Add((New-GuiLine 'A film collection can need hundreds of GB. To keep it on another drive - an external one, say - choose a folder there now. Moving it later means moving every file.' 13 '#9696A5'))
        # Where EmberStorm's own data goes with that choice, said here, with
        # C: kept as the choice where it has room.
        $keepOnC = $null
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            $was = $Library
            $Library = $path
            $saved = $script:DockerOnSystem
            $script:DockerOnSystem = $false
            $planned = Get-DockerDataRoot
            $script:DockerOnSystem = $saved
            $Library = $was
            $system = [IO.Path]::GetPathRoot($env:LOCALAPPDATA)
            $systemFree = 0
            try { $systemFree = (New-Object IO.DriveInfo $system).AvailableFreeSpace } catch { }
            $gap2 = New-Object System.Windows.Controls.Border
            $gap2.Height = 8
            [void]$page.Children.Add($gap2)
            $plannedRoot = if ($planned) { [IO.Path]::GetPathRoot($planned) } else { '' }
            $pathRoot = ''
            try { $pathRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path)) } catch { }
            if ($planned) {
                $where = if ($plannedRoot -ieq $pathRoot) { "on $($plannedRoot.TrimEnd('\')) too" } else { "on $($plannedRoot.TrimEnd('\')), inside this PC, as $($system.TrimEnd('\')) is short of room" }
                [void]$page.Children.Add((New-GuiLine "EmberStorm's own data (about 20 GB at first, growing with your library) is kept $where." 13 '#B9B9C6'))
                if ($systemFree -ge 25GB) {
                    $keepOnC = New-Object System.Windows.Controls.CheckBox
                    $keepOnC.IsChecked = [bool]$script:DockerOnSystem
                    $keepOnC.Margin = '0,8,0,0'
                    $keepOnC.Foreground = New-WpfBrush '#F2F2FA'
                    $keepOnC.Content = (New-GuiLine "Keep EmberStorm's own data on $($system.TrimEnd('\')) instead ($(Format-Size $systemFree) free)" 13 '#F2F2FA')
                    [void]$page.Children.Add($keepOnC)
                }
            } else {
                [void]$page.Children.Add((New-GuiLine "EmberStorm's own data - about 20 GB at first, growing with your library - is kept on $($system.TrimEnd('\')), inside this PC." 13 '#B9B9C6'))
            }
        }
        if ($Drives.Count -gt 1) {
            $gap = New-Object System.Windows.Controls.Border
            $gap.Height = 8
            [void]$page.Children.Add($gap)
            foreach ($drive in @($Drives | Sort-Object FreeSpace -Descending | Select-Object -First 6)) {
                $label = if ($drive.VolumeName) { " ($($drive.VolumeName))" } else { '' }
                [void]$page.Children.Add((New-GuiLine "$($drive.DeviceID)$label   $(Format-Size $drive.FreeSpace) free of $(Format-Size $drive.Size)" 13 '#7F7F90'))
            }
        }
        if ($problem) { [void]$page.Children.Add((New-GuiLine $problem 13 '#FF8A8A')) }
        $choice = Show-GuiPage $page @('Choose a different folder...', 'Continue')
        if ($keepOnC) { $script:DockerOnSystem = [bool]$keepOnC.IsChecked }
        if ($choice -ne 'Choose a different folder...') { break }
        $browser = New-Object System.Windows.Forms.FolderBrowserDialog
        $browser.Description = 'Choose where EmberStorm keeps your music, films and books. A folder called EmberStorm is made inside the one you pick.'
        $browser.ShowNewFolderButton = $true
        if ($browser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $resolved = Resolve-LibraryChoice $browser.SelectedPath
            if ($resolved.Path) { $path = $resolved.Path; $problem = '' } else { $problem = $resolved.Problem }
        }
        $browser.Dispose()
    }
    if ($path -eq $Default -and -not $Suggested) { return $null }
    return $path
}

# Read-LibraryLocation is the same question in the console, for a machine that
# cannot show a window.
function Read-LibraryLocation([string]$Default, $Drives) {
    $lines = @('Your music, films and books will be kept in:', "*  $Default", '')
    if ($Drives.Count -gt 1) {
        $lines += 'Free space on this PC:'
        foreach ($drive in $Drives) {
            $label = if ($drive.VolumeName) { " ($($drive.VolumeName))" } else { '' }
            $lines += "   $($drive.DeviceID)$label  $(Format-Size $drive.FreeSpace) free of $(Format-Size $drive.Size)"
        }
        $lines += ''
    }
    $lines += @('To keep it somewhere else - an external drive, say - type the folder.',
        'Moving it later means moving every file.')
    Callout 'Where should your library go?' $lines 'Cyan'
    try {
        $typed = Read-Host '    Press Enter to keep it there, or type a folder such as E:\Media'
    } catch {
        return $null
    }
    $resolved = Resolve-LibraryChoice $typed
    if ($resolved.Problem) {
        Important $resolved.Problem
        Note "Keeping the library in $Default."
    }
    return $resolved.Path
}

# Show-TailscaleDialog asks for a Tailscale auth key in a window that says
# what Tailscale is, what it needs, and exactly where the key comes from - with
# a button to that page. Returns the key, or '' when the person cancels.
#
# Tailscale is never asked about during an install (see CLAUDE.md, "Tailscale,
# and why it is a profile rather than a service"): it needs an account and an
# app on every device, which most people cannot answer yes to in the middle of
# a setup. This is what the "Set up Tailscale" shortcut opens, for the people
# who went looking for it - usually because the account panel told them remote
# access cannot work on their connection.
function Show-TailscaleDialog {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'EmberStorm - set up Tailscale'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.ClientSize = New-Object System.Drawing.Size(560, 430)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = "Tailscale lets your own phones and computers reach EmberStorm from anywhere, privately. Nothing is opened on your router, and it works on every kind of internet connection.`r`n`r`nIt needs a free Tailscale account, and the Tailscale app on each phone or computer that should connect, signed in to that same account."
    $intro.Location = New-Object System.Drawing.Point(20, 16)
    $intro.Size = New-Object System.Drawing.Size(520, 108)
    $form.Controls.Add($intro)

    $stepsLabel = New-Object System.Windows.Forms.Label
    $stepsLabel.Text = "1.  Click Open Tailscale, and sign up or sign in.`r`n2.  On the page that opens, click Generate auth key, then Generate key.`r`n3.  Copy the key and paste it here."
    $stepsLabel.Location = New-Object System.Drawing.Point(20, 130)
    $stepsLabel.Size = New-Object System.Drawing.Size(520, 72)
    $form.Controls.Add($stepsLabel)

    $openPage = New-Object System.Windows.Forms.Button
    $openPage.Text = 'Open Tailscale'
    $openPage.Location = New-Object System.Drawing.Point(20, 210)
    $openPage.Size = New-Object System.Drawing.Size(160, 34)
    $openPage.Add_Click({ Start-Process 'https://login.tailscale.com/admin/settings/keys' })
    $form.Controls.Add($openPage)

    $keyLabel = New-Object System.Windows.Forms.Label
    $keyLabel.Text = 'Auth key:'
    $keyLabel.Location = New-Object System.Drawing.Point(20, 262)
    $keyLabel.Size = New-Object System.Drawing.Size(520, 22)
    $form.Controls.Add($keyLabel)

    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(20, 286)
    $keyBox.Size = New-Object System.Drawing.Size(520, 28)
    $keyBox.UseSystemPasswordChar = $true
    $form.Controls.Add($keyBox)

    $problem = New-Object System.Windows.Forms.Label
    $problem.ForeColor = [System.Drawing.Color]::Firebrick
    $problem.Location = New-Object System.Drawing.Point(20, 320)
    $problem.Size = New-Object System.Drawing.Size(520, 44)
    $form.Controls.Add($problem)

    $connect = New-Object System.Windows.Forms.Button
    $connect.Text = 'Connect'
    $connect.Location = New-Object System.Drawing.Point(300, 378)
    $connect.Size = New-Object System.Drawing.Size(116, 34)
    $form.Controls.Add($connect)
    $form.AcceptButton = $connect

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(424, 378)
    $cancel.Size = New-Object System.Drawing.Size(116, 34)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    # Checked before the window closes, so a wrong paste - the key's name, the
    # page's URL, half a key - is caught while the page is still open to copy
    # from again, rather than as a sidecar that never joins the tailnet.
    $connect.Add_Click({
        $candidate = $keyBox.Text.Trim()
        if ($candidate -match '^tskey-[A-Za-z0-9-]{8,}$') {
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } else {
            $problem.Text = 'That does not look like a Tailscale auth key, which starts with tskey-. Copy it from the Tailscale page and paste it again.'
        }
    })

    $key = ''
    try {
        if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $key = $keyBox.Text.Trim()
        }
    } finally {
        $form.Dispose()
    }
    return $key
}

# Confirm-AlwaysOn asks, in one window, what keeps EmberStorm reachable all
# the time - a server is only as good as the PC staying on - and does what was
# ticked: staying awake while plugged in, not sleeping when a laptop's lid
# is closed (plugged in only), and signing in to Windows by itself after a
# restart, which Docker Desktop needs before EmberStorm can start. That last
# is off unless chosen, and says why: whoever switches the PC on gets into
# this Windows account (the owner's call, 2026-10-09).
# What the setup changes on Windows, and what was there before, kept in the
# person's own folder so an uninstall can offer to put each back - exactly as
# it was, not a guess. The first value kept is the one from before EmberStorm:
# a second install does not write over it.
$script:ChangesFile = Join-Path $env:LOCALAPPDATA 'EmberStorm\changes.json'
function Get-SetupChanges {
    $all = @{}
    try {
        $read = Get-Content -Raw -LiteralPath $script:ChangesFile -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $read.PSObject.Properties) { $all[$p.Name] = $p.Value }
    } catch { }
    return $all
}
function Save-SetupChange([string]$Name, $Value) {
    try {
        $all = Get-SetupChanges
        if ($all.ContainsKey($Name)) { return }
        $all[$Name] = $Value
        New-Item -ItemType Directory -Force -Path (Split-Path $script:ChangesFile) | Out-Null
        [IO.File]::WriteAllText($script:ChangesFile, ($all | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    } catch { }
}

# Get-PowerAcValue reads one plugged-in power setting of the plan in use: the
# second last hex number powercfg prints for it (then the battery's), as its
# words are in Windows' own language. $null when it cannot tell.
function Get-PowerAcValue([string]$Group, [string]$Setting) {
    try {
        $out = & (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\powercfg.exe') /query SCHEME_CURRENT $Group $Setting 2>$null
        $values = @($out | Where-Object { $_ -match ':\s*0x([0-9a-fA-F]{8})\s*$' } | ForEach-Object { [Convert]::ToInt64(($_ -replace '^.*0x', ''), 16) })
        if ($values.Count -ge 2) { return $values[$values.Count - 2] }
    } catch { }
    return $null
}

# Get-AutoSignIn answers whether Windows signs in by itself, and as whom.
function Get-AutoSignIn {
    try {
        $w = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        return @{ On = ("$($w.AutoAdminLogon)" -eq '1'); Who = "$($w.DefaultUserName)" }
    } catch {
        return @{ On = $false; Who = '' }
    }
}

# Get-PasswordLess reads the Windows 11 setting the auto sign-in turns off:
# its number, or 'absent'.
function Get-PasswordLess {
    try {
        $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' -ErrorAction Stop).DevicePasswordLessBuildVersion
        if ($null -ne $v) { return [int]$v }
    } catch { }
    return 'absent'
}

function Confirm-AlwaysOn {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
    } catch {
        return
    }
    $laptop = $false
    try { $laptop = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
    $powercfg = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\powercfg.exe'
    $sleepsNow = $true
    try {
        # The plugged-in value is the second last hex number powercfg prints
        # (then the battery's): its words are in Windows' own language.
        $out = & $powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
        $values = @($out | Where-Object { $_ -match ':\s*0x([0-9a-fA-F]{8})\s*$' } | ForEach-Object { [Convert]::ToInt64(($_ -replace '^.*0x', ''), 16) })
        if ($values.Count -ge 2 -and $values[$values.Count - 2] -eq 0) { $sleepsNow = $false }
    } catch { }

    $choices = @{}
    if ($script:Gui) {
        $page = New-GuiPageText 'Keep EmberStorm available' @('It can only be reached while this PC is on and awake. To keep it that way:')
        $checks = @{}
        $addCheck = {
            param($key, $text, $hint, $checked)
            $c = New-Object System.Windows.Controls.CheckBox
            $c.IsChecked = $checked
            $c.Margin = '0,14,0,0'
            $c.Foreground = New-WpfBrush '#F2F2FA'
            $c.VerticalContentAlignment = 'Top'
            $stack = New-Object System.Windows.Controls.StackPanel
            $stack.Margin = '6,-2,0,0'
            [void]$stack.Children.Add((New-GuiLine $text 15 '#F2F2FA' 'SemiBold'))
            [void]$stack.Children.Add((New-GuiLine $hint 13 '#9696A5'))
            $c.Content = $stack
            [void]$page.Children.Add($c)
            $checks[$key] = $c
        }
        if ($sleepsNow) { & $addCheck 'awake' 'Stay awake while plugged in' 'Asleep, nothing can reach it. The screen still turns off as usual.' $true }
        if ($laptop) { & $addCheck 'lid' 'Keep running with the lid closed (while plugged in)' 'On battery, closing the lid still puts it to sleep.' $true }
        & $addCheck 'signin' 'Sign in to Windows by itself after a restart' 'EmberStorm starts once Windows is signed in. After a power cut or an update restart, this signs in for you - but then anyone who switches this PC on gets into this Windows account. Best only for a PC kept just for EmberStorm.' $false
        [void](Show-GuiPage $page @('Continue'))
        foreach ($key in $checks.Keys) { $choices[$key] = [bool]$checks[$key].IsChecked }
    } else {
    Note "A window has opened asking how to keep EmberStorm available."
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'EmberStorm - keep it available'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-GuiFont 10
    $form.ClientSize = New-Object System.Drawing.Size(560, 390)

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = 'EmberStorm can only be reached while this PC is on and awake. To keep it that way:'
    $heading.Font = New-GuiFont 11 'Bold'
    $heading.Location = New-Object System.Drawing.Point(20, 16)
    $heading.Size = New-Object System.Drawing.Size(520, 48)
    $form.Controls.Add($heading)

    $y = 72
    $boxes = @{}
    $add = {
        param($key, $text, $hint, $checked)
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Text = $text
        $c.Checked = $checked
        $c.Font = New-GuiFont 10 'Bold'
        $c.Location = New-Object System.Drawing.Point(20, $script:alwaysY)
        $c.Size = New-Object System.Drawing.Size(520, 24)
        $form.Controls.Add($c)
        $h = New-Object System.Windows.Forms.Label
        $h.Text = $hint
        $h.ForeColor = [System.Drawing.Color]::DimGray
        $h.Location = New-Object System.Drawing.Point(38, ($script:alwaysY + 24))
        # Room for three lines: the sign-in one's catch must be read whole.
        $h.Size = New-Object System.Drawing.Size(500, 64)
        $form.Controls.Add($h)
        $script:alwaysY += 96
        $boxes[$key] = $c
    }
    $script:alwaysY = $y
    if ($sleepsNow) {
        & $add 'awake' 'Stay awake while plugged in' 'Asleep, nothing can reach it. The screen still turns off as usual.' $true
    }
    if ($laptop) {
        & $add 'lid' 'Keep running with the lid closed (while plugged in)' 'On battery, closing the lid still puts it to sleep.' $true
    }
    & $add 'signin' 'Sign in to Windows by itself after a restart' 'EmberStorm starts once Windows is signed in. After a power cut or an update restart, this signs in for you - but then anyone who switches this PC on gets into this Windows account. Best only for a PC kept just for EmberStorm.' $false

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Continue'
    $ok.Location = New-Object System.Drawing.Point(420, ($script:alwaysY + 8))
    $ok.Size = New-Object System.Drawing.Size(120, 34)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok
    $form.ClientSize = New-Object System.Drawing.Size(560, ($script:alwaysY + 58))
    Set-DarkTheme $form
    Set-PrimaryButton $ok
    $form.ActiveControl = $ok
    try {
        # Closed with the X: what it shows, as the library question takes it.
        [void]$form.ShowDialog()
    } finally {
        $form.Dispose()
    }
    foreach ($key in $boxes.Keys) { $choices[$key] = [bool]$boxes[$key].Checked }
    }

    if ($choices['awake']) {
        $was = Get-PowerAcValue 'SUB_SLEEP' 'STANDBYIDLE'
        if ($null -ne $was) { Save-SetupChange 'sleepAc' $was }
        $was = Get-PowerAcValue 'SUB_SLEEP' 'HIBERNATEIDLE'
        if ($null -ne $was) { Save-SetupChange 'hibernateAc' $was }
        $okAwake = ((Invoke-Native $powercfg @('/change', 'standby-timeout-ac', '0')).ExitCode -eq 0)
        $null = Invoke-Native $powercfg @('/change', 'hibernate-timeout-ac', '0')
        if ($okAwake) { Good "This PC stays awake while it is plugged in." }
        else { Note "Could not change the sleep setting. Set Sleep to Never in Windows Settings, System, Power." }
    }
    if ($choices['lid']) {
        $was = Get-PowerAcValue 'SUB_BUTTONS' 'LIDACTION'
        if ($null -ne $was) { Save-SetupChange 'lidAc' $was }
        $okLid = ((Invoke-Native $powercfg @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')).ExitCode -eq 0)
        $null = Invoke-Native $powercfg @('/setactive', 'SCHEME_CURRENT')
        if ($okLid) { Good "Closing the lid no longer sleeps it while plugged in." }
    }
    if ($choices['signin']) { Enable-AutoSignIn }
}

# Enable-AutoSignIn has Windows sign in by itself when the PC starts, by
# Windows' own way of doing it: its "Users must enter a user name and
# password" switch, which keeps the password itself, encrypted (never this
# setup, never a file). Windows 11 hides the switch while it prefers its own
# sign-in methods; a setting shows it again. The person unticks it and types
# their password - Windows asks, in its own window.
function Enable-AutoSignIn {
    if ($script:Gui) {
        $page = New-GuiPageText 'Signing in by itself' @(
            'Windows will ask for permission, then open its own User Accounts window. In it:',
            '',
            '1.  Untick "Users must enter a user name and password to use this computer".',
            '2.  Click OK.',
            '3.  Type your Windows password twice and click OK. For a Microsoft account, its password - not the PIN.',
            '',
            'If your account has no password, Windows already signs in by itself: just close that window.')
        [void](Show-GuiPage $page @('Continue'))
    } else {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
        $owner = New-TopmostOwner
        try {
            [void][System.Windows.Forms.MessageBox]::Show($owner,
                "Windows will now ask for permission, then open its own User Accounts window.`r`n`r`nIn it:`r`n  1. Untick ""Users must enter a user name and password to use this computer"".`r`n  2. Click OK.`r`n  3. Type your Windows password twice and click OK. (For a Microsoft account, its password - not the PIN.)`r`n`r`nIf your account has no password, Windows already signs in by itself: just close that window.",
                'EmberStorm - signing in by itself',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
        } finally {
            $owner.Dispose()
        }
    } catch { }
    }
    $signedInBefore = (Get-AutoSignIn).On
    $before = Get-PasswordLess
    Save-SetupChange 'passwordLess' $before
    # Closed without turning it on (or already on): the Windows 11 setting
    # put straight back, in the same permission (the blind review: it stayed
    # off for good, never offered back). A number or a fixed word only.
    $putBackNow = if ($before -eq 'absent') { "Remove-ItemProperty -Path `$key -Name 'DevicePasswordLessBuildVersion'" } else { "Set-ItemProperty -Path `$key -Name 'DevicePasswordLessBuildVersion' -Value $([int]$before) -Type DWord" }
    $script = @'
$ErrorActionPreference = 'SilentlyContinue'
$env:PSModulePath = "$PSHOME\Modules"
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord
Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\netplwiz.exe') -Wait
if ("$((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').AutoAdminLogon)" -ne '1') { PUTBACK }
exit 0
'@
    $script = $script.Replace('PUTBACK', $putBackNow)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $code = Invoke-Elevated (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    if ($null -eq $code) {
        Note "Signing in by itself was not set up (no permission). You can do it later: run netplwiz from the Start menu."
    } else {
        # Read back rather than guessed: netplwiz writes this when the box
        # is unticked and the password given.
        $auto = ''
        try { $auto = "$((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop).AutoAdminLogon)" } catch { }
        $who = ''
        try { $who = "$((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop).DefaultUserName)" } catch { }
        if ($auto -eq '1' -and $who -and $who -ne $env:USERNAME -and $who -notlike "*\$env:USERNAME" -and $who -notlike "$env:USERNAME@*") {
            Important "Windows will sign in by itself as $who, not as you - EmberStorm runs in your account. To change it, run netplwiz from the Start menu and choose your own name."
            if ($script:Gui) {
                [void](Show-GuiPage (New-GuiPageText 'Signing in as someone else' @(
                    "Windows will sign in by itself as $who - not as you, and EmberStorm runs in your account.",
                    '',
                    'To change it: open the Start menu, type netplwiz, choose your own name, untick "Users must enter a user name and password", and click OK.')) @('OK'))
            }
        } elseif ($auto -eq '1') {
            if (-not $signedInBefore) { Save-SetupChange 'autoSignIn' $true }
            Good "Windows will sign in by itself when the PC starts."
            Write-Host "    (Signing in with a password is allowed again on this PC, for every account - Windows needed that for it.)"
        } else {
            Note "Signing in by itself was not turned on. You can do it later: run netplwiz from the Start menu."
        }
    }
}

# Test-DownloadRoom stops before the long download when the drive Docker keeps
# it on has too little room, saying how much and what to do.
# Test-InternalDrive says whether a drive is inside the PC and can hold
# Docker's data: fixed, NTFS, and not on USB, SD or FireWire - many USB hard
# drives call themselves fixed disks, so how it is connected is asked of
# Windows (readable without permission). A drive Windows cannot say about
# counts as inside when it is fixed and NTFS.
function Test-InternalDrive([string]$Root) {
    try {
        $info = New-Object IO.DriveInfo $Root
        if ("$($info.DriveType)" -ne 'Fixed' -or $info.DriveFormat -ne 'NTFS') { return $false }
    } catch { return $false }
    try {
        $bus = "$((Get-Partition -DriveLetter $Root.Substring(0, 1) -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType)"
        if ($bus -in @('USB', 'SD', '1394')) { return $false }
    } catch { }
    return $true
}

# Get-DockerDataRoot answers where Docker should keep its downloads and data -
# EmberStorm's own data, about 20GB at first and growing with the library
# (thumbnails, the media servers' databases) - when Docker is still to be
# installed: a folder on the library's drive when that drive is another one
# inside the PC, so everything EmberStorm keeps is on the drive the person
# chose and C: does not slowly fill; with the library on C:, or chosen to stay
# there, $null - where Docker puts it; with the library on a drive that can be
# unplugged, C:, or the roomiest drive inside the PC when C: is short. Never
# on a drive that can be unplugged: EmberStorm would break with it (the owner's
# design, 2026-10-10, after the test box's 64GB C: had 8GB left beside a 1TB
# drive). Docker's installer takes it as --wsl-default-data-root.
function Get-DockerDataRoot {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return $null }
    try {
        $system = [IO.Path]::GetPathRoot($env:LOCALAPPDATA)
        $systemFree = (New-Object IO.DriveInfo $system).AvailableFreeSpace
        $library = if ($Library) { "$Library" } else { Get-LibraryPath }
        $libraryRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($library))
        if ($script:DockerOnSystem -or $env:EMBERSTORM_DOCKER_C -eq '1') {
            if ($systemFree -ge 25GB) { return $null }
        }
        if ($libraryRoot -ine $system -and (Test-InternalDrive $libraryRoot)) { return (Join-Path $libraryRoot 'EmberStorm-Docker') }
        # The library on C: or on a drive that can be unplugged: Docker stays
        # on C: when it has room, else the roomiest drive inside the PC.
        if ($systemFree -ge 25GB) { return $null }
        $best = $null
        foreach ($drive in Get-LocalDrives) {
            $root = "$($drive.DeviceID)\"
            if ($root -ieq $system -or -not (Test-InternalDrive $root)) { continue }
            $info = New-Object IO.DriveInfo $root
            if ($info.AvailableFreeSpace -lt 20GB) { continue }
            if (-not $best -or $info.AvailableFreeSpace -gt $best.AvailableFreeSpace) { $best = $info }
        }
        if ($best) { return (Join-Path $best.RootDirectory.FullName 'EmberStorm-Docker') }
    } catch { }
    return $null
}

function Test-DownloadRoom([long]$Need = 20GB) {
    try {
        $root = [IO.Path]::GetPathRoot($env:LOCALAPPDATA)
        $free = (New-Object IO.DriveInfo $root).AvailableFreeSpace
    } catch {
        return
    }
    # Docker's data on another drive: that drive needs the room for the
    # downloads, and this one only enough for Docker itself.
    $elsewhere = Get-DockerDataRoot
    if ($elsewhere) {
        $other = [IO.Path]::GetPathRoot($elsewhere)
        $otherFree = 0
        try { $otherFree = (New-Object IO.DriveInfo $other).AvailableFreeSpace } catch { }
        if ($otherFree -lt 20GB) {
            Stop-With @"
  EmberStorm's own data needs about 20 GB free on $($other.TrimEnd('\')), and it has $(Format-Size $otherFree).

  Free some space there - Settings, System, Storage shows what is using it -
  or choose another drive for the library, then run the setup again.
"@
        }
        if ($free -ge 5GB) { return }
        Stop-With @"
  Docker needs about 5 GB free on $($root.TrimEnd('\')) to install itself, and it has $(Format-Size $free).
  (Its downloads will go on $($other.TrimEnd('\')), which has room.)

  Free some space there - Settings, System, Storage shows what is using it -
  then run the setup again.
"@
    }
    if ($free -ge $Need) { return }
    Stop-With @"
  EmberStorm's programs need about $([int]($Need / 1GB)) GB free on $($root.TrimEnd('\')), where Docker
  keeps them, and it has $(Format-Size $free).

  Free some space there - Settings, System, Storage shows what is using it -
  then run the setup again. (A second drive inside the PC with 20 GB free
  would take Docker's downloads instead.)
"@
}

# Confirm-HomeNetwork asks the network question in a Yes/No window, falling
# back to the console only where no window can be shown. Returns $true for yes.
function Confirm-HomeNetwork([string]$NetworkName) {
    if ($script:Gui) {
        $page = New-GuiPageText 'Is this your home network?' @(
            "Windows is treating the network this PC is on (""$NetworkName"") as public - the setting for cafes and airports - so your phone, TV and other computers cannot reach EmberStorm.",
            '',
            'Yes: EmberStorm marks it as private so your other devices can connect. Windows will ask for permission. (Private also lets Windows share files and printers on it, as on any home network.)',
            'No: nothing is changed.')
        return ((Show-GuiPage $page @('No', 'Yes, it is my home network')) -like 'Yes*')
    }
    $text = "Windows is treating the network this PC is on (""$NetworkName"") as public - the setting for cafes and airports - so your phone, TV and other computers cannot reach EmberStorm.`r`n`r`nIs this your own home network?`r`n`r`nYes: EmberStorm marks it as private so your other devices can connect. Windows will ask for permission.`r`nNo: nothing is changed."
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
    } catch {
        try {
            return ((Read-Host '    Is this your home network? Type Y or N, then press Enter') -match '^\s*y')
        } catch {
            # No console to ask on either: change nothing, the safe answer.
            return $false
        }
    }
    Note "A window has opened asking about your network."
    $owner = New-TopmostOwner
    try {
        $answer = [System.Windows.Forms.MessageBox]::Show($owner, $text,
            'EmberStorm - is this your home network?',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
    } finally {
        $owner.Dispose()
    }
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Get-InstalledURL is where an install answers, read from its own .env rather
# than assumed. Falls back to the first port and plain http, which is what a
# .env too old to carry either of them meant.
function Get-InstalledURL([string]$Folder) {
    $port = Get-EnvSettingIn $Folder 'SOUNDSTORM_PORT'
    if ($port -notmatch '^\d+$') { $port = "$FirstPort" }
    $scheme = ConvertTo-Scheme (Get-EnvSettingIn $Folder 'SOUNDSTORM_TLS')
    return "${scheme}://localhost:$port"
}

# ConvertTo-Scheme is the scheme to hand somebody for a TLS setting. Auto mode
# is http: it answers http and https on the same port, http works from the
# first second, and the page moves itself to the real https address once it
# has checked this browser can reach it. Only self-signed and file are https
# alone.
function ConvertTo-Scheme([string]$Tls) {
    if ($Tls -eq 'self-signed' -or $Tls -eq 'file') { return 'https' }
    return 'http'
}

# Set-EnvSetting rewrites one line of .env and leaves the rest alone, because
# the port and the certificate hosts are in there too and were worked out on a
# run nobody is going to repeat.
function Set-EnvSetting([string]$Name, [string]$Value) {
    $Value = $Value -replace '[\r\n]', ''
    $envFile = Join-Path $Dir '.env'
    $lines = @()
    if (Test-Path $envFile) { $lines = @(Get-Content -Encoding UTF8 $envFile) }
    $pattern = "^\s*$([regex]::Escape($Name))="
    $kept = @($lines | Where-Object { $_ -notmatch $pattern })
    # A $ goes in as $$: compose reads a lone $ as the start of a variable,
    # and a library folder called "My$Music" mounted as "My" (the twelfth
    # security pass). Get-EnvSettingIn reads it back as one.
    $kept += "$Name=" + $Value.Replace('$', '$$')
    # UTF-8 without a byte order mark, which compose reads: ASCII turned a
    # library folder like D:\Musica with an accent into a question mark, and
    # every shelf failed to mount (a review).
    [IO.File]::WriteAllLines($envFile, [string[]]$kept, (New-Object Text.UTF8Encoding $false))
    Protect-SecretFile $envFile
}

# A folder outside this user's own (C:\EmberStorm, a second drive) could have
# been made, or filled, by another account on the PC: a compose file or a
# settings file of theirs would run as this user's install. So the folder and
# what EmberStorm keeps there must be this user's own (the twelfth security
# pass). Inside the user's folder only they could have put anything.
# Test-OthersCanWrite says whether any account but this person, SYSTEM and
# Administrators may add, change or delete things in a folder.
function Test-OthersCanWrite([string]$Path) {
    try {
        $mine = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0')
        # Write data, add folders, delete children, delete, change permissions,
        # take ownership, generic all and generic write.
        $mask = [int64]0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
        foreach ($rule in (Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ("$($rule.AccessControlType)" -ne 'Allow') { continue }
            if ($mine -contains $rule.IdentityReference.Value) { continue }
            if (([int64]$rule.FileSystemRights -band $mask) -ne 0) { return $true }
        }
    } catch { }
    return $false
}

# Protect-PrivateFolder gives a folder, and what is made in it, to this person,
# SYSTEM and Administrators only. Only the access list is written (as
# Protect-SecretFile does), which needs no privilege an ordinary account lacks.
function Protect-PrivateFolder([string]$Path) {
    try {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($who in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
                (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'),
                (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $who, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        }
        (New-Object IO.DirectoryInfo $Path).SetAccessControl($acl)
        return $true
    } catch {
        return $false
    }
}

function Test-OwnedByMe([string]$Path) {
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent()
        $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier])
        $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
        return ($owner -eq $me.User) -or ($owner -eq $admins -and (Test-AdminAccount))
    } catch {
        return $true # cannot tell (a drive with no ACLs): as before
    }
}

# Protect-SecretFile makes a file readable by this user only - plus SYSTEM and
# Administrators, who can take ownership of anything anyway.
#
# .env holds the first sign-up's setup code and, with -Tailscale, a reusable
# auth key; the uninstaller's backup holds the password EmberStorm made on every
# media server. Left alone, a file inherits its folder's permissions. Under the
# user profile, the default, that already keeps other users out - but the
# install can live anywhere (SOUNDSTORM_DIR), and a folder like C:\EmberStorm
# inherits "Users: read" from the drive. install.sh gets the same protection
# from umask 077.
#
# Accounts are named by SID rather than by name, because group names are
# localized: "Administrators" is "Administratoren" on a German Windows, and a
# lookup by name would fail there. Best effort: a file that cannot be locked
# down still works, and refusing to install over it would be the worse failure.
function Protect-SecretFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        # Protected, and inherited entries not copied: only the rules below.
        $acl.SetAccessRuleProtection($true, $false)
        $owners = @(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
            (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'),     # SYSTEM
            (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544')  # Administrators
        )
        foreach ($sid in $owners) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'Allow')))
        }
        # Not Set-Acl: in Windows PowerShell it writes every section of the
        # descriptor, the audit list included, and writing that needs
        # SeSecurityPrivilege - which an ordinary account does not hold. It
        # worked on the development machine and failed on a laptop with
        # "The process does not possess the 'SeSecurityPrivilege' privilege".
        # SetAccessControl writes only the sections that were changed here,
        # which is the permission list and nothing else.
        (Get-Item -LiteralPath $Path -Force).SetAccessControl($acl)
        return
    } catch {
        $firstError = $_.Exception.Message
    }
    # icacls is the second way to say the same thing, and names the accounts by
    # SID too, so it is not thrown by a localized "Administrators".
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $result = Invoke-Native 'icacls.exe' @($Path, '/inheritance:r', '/grant:r',
        "*${me}:F", '*S-1-5-18:F', '*S-1-5-32-544:F')
    if ($result.ExitCode -eq 0) { return }
    # Not fatal: the folder's own permissions still apply, and under the user
    # profile those already keep other accounts out. Said once, plainly.
    Note "Could not tighten the permissions on $([IO.Path]::GetFileName($Path)) ($firstError)."
    Note "EmberStorm works normally; keep this PC's other accounts in mind."
}

function Get-InstalledPort {
    $port = Get-EnvSetting 'SOUNDSTORM_PORT'
    if ($port -match '^\d+$') { return [int]$port }
    return $FirstPort
}

# Write-ServeConfig writes the file Tailscale proxies through.
#
# The scheme matters and is the one thing that cannot be a constant: Tailscale
# talks to EmberStorm over the internal compose network, and EmberStorm is
# either speaking plain HTTP there or its own self-signed HTTPS depending on
# what -Https did. Point the proxy at the wrong one and the tailnet address
# answers 502 while everything else looks fine.
#
# https+insecure is Tailscale's documented pseudo-scheme for a backend with a
# certificate nothing can validate, which is exactly what a local authority
# issues. The hop is inside Docker's own network either way.
function Write-ServeConfig {
    $target = if ((Get-InstalledScheme) -eq 'https') {
        'https+insecure://soundstorm-app:8080'
    } else {
        'http://soundstorm-app:8080'
    }
    $json = @"
{
  "TCP": { "443": { "HTTPS": true } },
  "Web": {
    "`${TS_CERT_DOMAIN}:443": {
      "Handlers": {
        "/": { "Proxy": "$target" }
      }
    }
  }
}
"@
    $json | Out-File -FilePath (Join-Path $Dir 'tailscale-serve.json') -Encoding ascii
}

# Get-TailnetURL asks the running Tailscale container where it ended up.
#
# The address is assigned by Tailscale, not chosen here - it is the hostname
# plus whatever the tailnet is called - so the only honest way to print it is
# to ask after the fact.
function Get-TailnetURL {
    for ($waited = 0; $waited -lt 60; $waited += 3) {
        $status = Invoke-Docker @('exec', 'soundstorm-tailscale', 'tailscale', 'status', '--json') -Capture
        if ($status.ExitCode -eq 0) {
            try {
                $parsed = $status.Output | ConvertFrom-Json
                $name = $parsed.Self.DNSName
                if ($name) { return "https://" + $name.TrimEnd('.') }
            } catch {
                # Still coming up; it prints something that is not JSON yet.
            }
        }
        Start-Sleep -Seconds 3
    }
    return ''
}

# Get-InstalledScheme reads what this install is actually serving rather than
# assuming http. Telling somebody the wrong scheme hands them a browser error
# with no hint in it, which is worse than telling them nothing.
function Get-InstalledScheme {
    return ConvertTo-Scheme (Get-EnvSetting 'SOUNDSTORM_TLS')
}

# Get-SecureAddress waits briefly for auto mode's real https address, asking
# EmberStorm itself over plain http on this machine - so no certificate is
# involved in the asking. The name arrives within seconds of the certificate,
# which usually takes ten or twenty; empty if it has not by the deadline, and
# the http address works meanwhile.
# Get-HasAccount asks the running server whether the first account exists yet.
# $true or $false, or $null when it cannot tell - the setup code is only worth
# showing while nobody has signed up, since it is read by the first sign-up
# alone.
function Get-HasAccount([string]$Url) {
    $priorCallback = $null
    $bypassed = $false
    if ($Url -like 'https://*') {
        # A certificate this PC minted, on this PC; same reasoning as
        # Wait-ForEmberStorm.
        $priorCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $bypassed = $true
    }
    try {
        $request = [Net.HttpWebRequest]::Create("$Url/api/session")
        $request.Timeout = 5000
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        $body = $reader.ReadToEnd()
        $response.Close()
        return [bool](($body | ConvertFrom-Json).hasAccount)
    } catch {
        return $null
    } finally {
        if ($bypassed) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $priorCallback }
    }
}

# Format-SetupCode groups the code in fours so it can be read off the screen and
# typed. The server ignores case, spaces and dashes, so this is presentation.
function Format-SetupCode([string]$Code) {
    $plain = ($Code -replace '[-\s]', '').ToUpperInvariant()
    return (($plain -split '(.{4})' | Where-Object { $_ }) -join '-')
}

function Get-SecureAddress([int]$Port) {
    for ($waited = 0; $waited -lt 45; $waited += 3) {
        try {
            $request = [Net.HttpWebRequest]::Create("http://localhost:$Port/api/session")
            $request.Timeout = 5000
            $response = $request.GetResponse()
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $body = $reader.ReadToEnd()
            $response.Close()
            $name = ($body | ConvertFrom-Json).secureName
            if ($name) { return "https://${name}:$Port" }
        } catch {
            # Still starting; ask again.
        }
        Start-Sleep -Seconds 3
    }
    return ''
}

# New-Shortcut writes a .lnk. WScript.Shell is the only way to do that without
# shipping a compiled helper, and it is on every Windows since XP.
function New-Shortcut($Path, $Target, $Arguments, $WorkingDirectory, $Description, $Minimized) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $Target
    if ($Arguments) { $link.Arguments = $Arguments }
    if ($WorkingDirectory) { $link.WorkingDirectory = $WorkingDirectory }
    $link.Description = $Description
    # 7 is minimized: the launcher makes sure Docker is up before opening a
    # browser, and that is not work anybody wants to watch.
    if ($Minimized) { $link.WindowStyle = 7 }
    $link.Save()
}

function Install-Shortcuts {
    $localScript = Join-Path $Dir 'soundstorm.ps1'
    $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # -WindowStyle Hidden as well as the minimized shortcut: minimized still
    # puts a console on the taskbar for the second it takes.
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$localScript`" -Launch"

    # Shortcuts from before the rename go, or both names would sit side by side.
    Remove-Shortcuts -OldOnly
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Shortcut (Join-Path $startMenu 'EmberStorm.lnk') $powershell $arguments $Dir `
        'Open your media library' $true
    New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'EmberStorm.lnk') `
        $powershell $arguments $Dir 'Open your media library' $true

    # Somewhere to put files, one click away. The app takes a drag-and-drop
    # too, but a folder is what people reach for with a hard drive of music.
    New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'EmberStorm media.lnk') `
        (Get-LibraryPath) $null $null 'Put your music, films and books in here' $false

    # Updating is re-running the installer, so the shortcut is the installer.
    New-Shortcut (Join-Path $startMenu 'Update EmberStorm.lnk') $powershell `
        "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$localScript`"" $Dir `
        'Get the newest version of EmberStorm' $true

    # Moving the library is the one change somebody may want long after
    # installing, and -Library is a command-line option. A shortcut that opens
    # the same window a first install shows means nobody has to type it.
    New-Shortcut (Join-Path $startMenu 'Move EmberStorm library.lnk') $powershell `
        "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$localScript`" -ChooseLibrary" $Dir `
        'Keep your music, films and books in a different folder or drive' $true

    # Moving to a new computer, the same way: a window and a folder picker,
    # never a typed path.
    New-Shortcut (Join-Path $startMenu 'Move EmberStorm to another computer.lnk') $powershell `
        "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$localScript`" -Move" $Dir `
        'Pack up EmberStorm, with your accounts and media, to move to a new computer' $true

    # Tailscale is offered where it is needed - the account panel points here
    # when remote access cannot work on a connection - not asked about during
    # every install. This is the click-through way in; -Tailscale is the same.
    New-Shortcut (Join-Path $startMenu 'Set up Tailscale.lnk') $powershell `
        "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$localScript`" -Tailscale" $Dir `
        'Reach EmberStorm privately from your own devices, from anywhere' $true

    if (-not $NoAutoStart) {
        $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
        New-Shortcut (Join-Path $startup 'EmberStorm.lnk') $powershell `
            "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$localScript`" -Launch -NoBrowser" $Dir `
            'Start EmberStorm with Windows' $true
    }
    Register-Uninstaller
    Good "Added EmberStorm to the Start menu and the desktop."
}

# uninstallKey is where Windows looks for what can be removed.
#
# Under HKCU rather than HKLM because EmberStorm installs per-user, into the
# user's own folder, without administrator rights. It shows up in Settings,
# Apps, where people actually go to remove something - a program that can only
# be uninstalled by finding instructions on a web page is not really
# uninstallable.
# The key keeps the name it had as SoundStorm, so an install made then is
# updated in place rather than listed twice; what Settings shows is DisplayName.
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SoundStorm'

# Test-InstalledHere says whether EmberStorm has been installed in $Dir and
# started at least once - not merely whether its compose file is there: that
# is written before the long download, so a first install stopped part way
# was taken for an update from then on, skipping the room check and its
# questions (the bug review). Installs from before the mark have an uninstall
# entry, written only once one had started.
function Test-InstalledHere {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'docker-compose.yml'))) { return $false }
    if ((Get-EnvSetting 'SOUNDSTORM_INSTALLED') -eq '1') { return $true }
    try { $where = "$((Get-ItemProperty -Path $uninstallKey -ErrorAction Stop).InstallLocation)" } catch { $where = '' }
    return [bool]($where -and $where.TrimEnd('\') -eq $Dir.TrimEnd('\'))
}

function Register-Uninstaller {
    try {
        $localScript = Join-Path $Dir 'soundstorm.ps1'
        $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'

        New-Item -Path $uninstallKey -Force | Out-Null

        # Split by type rather than choosing one inline: PowerShell 5.1 will
        # not take an `if` as an argument expression, and a tokenizer check
        # does not catch that.
        $strings = @{
            DisplayName     = 'EmberStorm'
            DisplayVersion  = '0.1'
            Publisher       = 'EmberStorm'
            InstallLocation = $Dir
            URLInfoAbout    = 'https://github.com/GabrielHollberg/emberstorm'
            UninstallString = "`"$powershell`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$localScript`" -Uninstall"
        }
        foreach ($name in $strings.Keys) {
            New-ItemProperty -Path $uninstallKey -Name $name -Value $strings[$name] `
                -PropertyType String -Force | Out-Null
        }
        foreach ($name in @('NoModify', 'NoRepair')) {
            New-ItemProperty -Path $uninstallKey -Name $name -Value 1 `
                -PropertyType DWord -Force | Out-Null
        }
    } catch {
        # Being absent from the app list is untidy, not broken.
        Note "Could not register the uninstaller: $($_.Exception.Message)"
    }
}

# Remove-Shortcuts takes away the shortcuts under the product's names - its
# own and the old SoundStorm ones, or only the old ones (-OldOnly, as an update
# replaces them).
function Remove-Shortcuts([switch]$OldOnly) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $names = if ($OldOnly) { @('SoundStorm') } else { @('EmberStorm', 'SoundStorm') }
    $paths = @()
    foreach ($n in $names) {
        $paths += @(
            (Join-Path $desktop "$n.lnk"),
            (Join-Path $desktop "$n media.lnk"),
            (Join-Path $programs "$n.lnk"),
            (Join-Path $programs "Update $n.lnk"),
            (Join-Path $programs "Move $n library.lnk"),
            (Join-Path $programs "Move $n to another computer.lnk"),
            (Join-Path $programs "Startup\$n.lnk")
        )
    }
    if (-not $OldOnly) { $paths += (Join-Path $programs 'Set up Tailscale.lnk') }
    foreach ($path in $paths) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

# --- removing it ---------------------------------------------------------------

if ($Uninstall) {
    # In a window: started from Settings, Apps, this runs with no console to
    # read, and said nothing at all (a review).
    if ($env:SOUNDSTORM_WINDOW -eq '1' -and $script:WindowWanted) {
        try {
            New-SetupWindow 'Removing EmberStorm' 'Your music, films, books and photos are never deleted - only the app is removed.' `
                @('Saving your accounts', 'Stopping EmberStorm', 'Removing shortcuts', 'Tidying up')
        } catch {
            $script:Gui = $null
        }
    }
    Write-Host ""
    Write-Host "  Removing EmberStorm" -ForegroundColor White
    Write-Host "  -----------------------------------------------------------"
    $stillRunning = $false
    $stopReason = ''
    $partly = $false
    $backupSaved = $false

    # What else to take back, asked first - only what the setup changed (or,
    # for an install from before it kept a record, what is still exactly as
    # EmberStorm leaves it), each its own choice: somebody may have come to
    # want a PC that never sleeps (the owner's design, 2026-10-10).
    $changes = Get-SetupChanges
    $known = $changes.Count -gt 0
    $offer = [ordered]@{}
    if (Get-DockerDesktopPath) {
        # Docker, sleep and the lid start unticked: things somebody may have
        # come to use for other things stay unless asked (the owner's call).
        $offer['docker'] = @{ Text = 'Remove Docker Desktop'; Checked = $false
            Hint = $(if ($changes['docker']) { 'It was installed for EmberStorm. Tick it to remove it, if nothing else on this PC uses it.' } else { 'It was on this PC before EmberStorm, or EmberStorm does not know. Tick it only if nothing else uses it - removing it removes everything in it. EmberStorm''s own programs inside it are removed either way.' }) }
    }
    $sleepNow = Get-PowerAcValue 'SUB_SLEEP' 'STANDBYIDLE'
    $sleepWas = if ($null -ne $changes['sleepAc']) { [int64]$changes['sleepAc'] } elseif (-not $known) { 1800 } else { $null }
    if ($sleepNow -eq 0 -and $null -ne $sleepWas -and $sleepWas -ne 0) {
        $offer['sleep'] = $(if ($known) { @{ Text = 'Let this PC sleep when idle again, as before'; Checked = $false; Hint = 'EmberStorm kept it awake while plugged in. Tick it to put that back.' } } else { @{ Text = 'Let this PC sleep when idle again'; Checked = $false; Hint = 'It never sleeps while plugged in now. If EmberStorm set that, tick this to have it sleep after 30 minutes again.' } })
    }
    $laptop = $false
    try { $laptop = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
    $lidNow = Get-PowerAcValue 'SUB_BUTTONS' 'LIDACTION'
    $lidWas = if ($null -ne $changes['lidAc']) { [int64]$changes['lidAc'] } elseif (-not $known -and $laptop) { 1 } else { $null }
    if ($lidNow -eq 0 -and $null -ne $lidWas -and $lidWas -ne 0) {
        $offer['lid'] = $(if ($known) { @{ Text = 'Put the lid setting back'; Checked = $false; Hint = 'Closing the lid while plugged in would sleep it again, as before.' } } else { @{ Text = 'Sleep when the lid is closed'; Checked = $false; Hint = 'Closing the lid while plugged in does nothing now. If EmberStorm set that, tick this.' } })
    }
    $autoNow = Get-AutoSignIn
    if ($autoNow.On -and ($changes['autoSignIn'] -or (-not $known -and (Get-PasswordLess) -eq 0))) {
        $offer['signin'] = $(if ($known) { @{ Text = 'Ask for a password at sign-in again'; Checked = $true; Hint = 'EmberStorm had Windows sign in by itself after a restart.' } } else { @{ Text = 'Ask for a password at sign-in again'; Checked = $false; Hint = 'Windows signs in by itself now. If EmberStorm set that, tick this.' } })
    }
    $offer['backup'] = @{ Text = 'Keep a copy of your accounts'; Checked = $true; Hint = 'For if you install EmberStorm again: the accounts and the passwords it made, in a file in the EmberStorm folder. Untick it to leave nothing of them.' }

    $want = @{}
    foreach ($key in $offer.Keys) { $want[$key] = $offer[$key].Checked }
    if ($script:Gui) {
        $page = New-GuiPageText 'A few choices first' @('Your music, films, books and photos are always kept. And:')
        $checks = @{}
        foreach ($key in $offer.Keys) {
            $c = New-Object System.Windows.Controls.CheckBox
            $c.IsChecked = $offer[$key].Checked
            $c.Margin = '0,14,0,0'
            $c.Foreground = New-WpfBrush '#F2F2FA'
            $c.VerticalContentAlignment = 'Top'
            $stack = New-Object System.Windows.Controls.StackPanel
            $stack.Margin = '6,-2,0,0'
            [void]$stack.Children.Add((New-GuiLine $offer[$key].Text 15 '#F2F2FA' 'SemiBold'))
            [void]$stack.Children.Add((New-GuiLine $offer[$key].Hint 13 '#9696A5'))
            $c.Content = $stack
            [void]$page.Children.Add($c)
            $checks[$key] = $c
        }
        $answer = Show-GuiPage $page @('Cancel', 'Uninstall') 'Uninstall'
        if ($answer -ne 'Uninstall') {
            $script:Gui.Running = $false
            try { $script:Gui.Window.Close() } catch { }
            exit 0
        }
        foreach ($key in $checks.Keys) { $want[$key] = [bool]$checks[$key].IsChecked }
        Clear-Resume
    } else {
        Clear-Resume
        # No window to ask in: nothing taken that was not asked about - Docker
        # stays; only settings the setup itself recorded are put back.
        $want['docker'] = $false
        if (-not $known) { $want['sleep'] = $false; $want['lid'] = $false; $want['signin'] = $false }
    }

    $askedDocker = [bool]$want['docker']
    $hadInstall = Test-Path -LiteralPath (Join-Path $Dir 'docker-compose.yml')
    $script:CloseQuestion = "EmberStorm is being removed.`r`n`r`nStop now? Uninstall it again later from Settings, Apps to finish."

    $library = Get-LibraryPath
    $hasLibrary = Test-Path $library

    if (-not (Test-Path (Join-Path $Dir 'docker-compose.yml'))) {
        Note "Nothing installed in $Dir - tidying up shortcuts anyway."
    } else {
        Set-Location $Dir
        # Docker started if it is not: without it nothing below could stop or
        # remove anything, and the uninstall said it was gone anyway.
        if ((Get-Command docker -ErrorAction SilentlyContinue) -and -not (Test-DockerRunning)) {
            $null = Start-Docker -NoStop
        }
        # Docker removed already: nothing of EmberStorm is left running, and
        # waiting for a Docker that is not there kept the uninstall from ever
        # finishing (the blind review).
        $dockerGone = -not (Get-Command docker -ErrorAction SilentlyContinue) -and -not (Get-DockerDesktopPath)
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            Step "Step 1 of 4 - Saving your accounts"
            # A copy first, into the folder rather than the volume about to be
            # deleted. This is the exact moment the credentials for four
            # backends stop existing anywhere, and somebody uninstalling to
            # move machines has no other warning that they were about to.
            $backup = Join-Path $Dir 'soundstorm-backup.json'
            $backupSaved = $false
            if ($want['backup']) {
                $saved = Invoke-Docker @(
                    'compose', 'run', '--rm', '-v', "${Dir}:/backup",
                    'soundstorm', 'backup', '/backup/soundstorm-backup.json'
                ) -Capture
                if ($saved.ExitCode -eq 0 -and (Test-Path $backup)) {
                    # Written by the container through a bind mount, so it arrives
                    # with the folder's permissions; it holds every media server's
                    # password, so it gets this user's alone.
                    Protect-SecretFile $backup
                    $backupSaved = $true
                    Good "Saved to $backup"
                    Note "Keep it if you might reinstall - it is the only copy of the passwords EmberStorm made on the media servers."
                } else {
                    # Not fatal: somebody uninstalling has asked to lose this, and
                    # refusing to uninstall because the backup failed is worse.
                    Note "Could not save a copy. Carrying on with the uninstall."
                }
            }

            Step "Step 2 of 4 - Stopping EmberStorm"
            Note "Accounts and the servers' own settings go; your media does not."
            # down -v takes the named volumes with it: EmberStorm's accounts,
            # and Jellyfin's and Navidrome's own databases. The library is a
            # bind mount from the folder and is not touched by this.
            # With the remote-access profile too, or its container would be
            # left running and the network it holds would fail the rest.
            # Which programs are EmberStorm's, read before they are stopped:
            # taken out of Docker after, 12GB that was left inside it.
            $ours = @(((Invoke-Docker @('compose', '--profile', 'tailscale', 'config', '--images') -Capture).Output -split "`r?`n") | Where-Object { $_ -match '^\S+$' })
            $down = Invoke-Docker @('compose', '--profile', 'tailscale', 'down', '-v') -Capture
            if ($down.ExitCode -ne 0) {
                $stillRunning = $true
                $stopReason = 'Docker could not stop it - restarting the PC usually lets it.'
            } else {
                # EmberStorm's own programs out of Docker, whatever becomes of
                # Docker itself (were it kept after all, they stayed).
                Note "Removing EmberStorm's programs from Docker."
                foreach ($image in $ours) { $null = Invoke-Docker @('image', 'rm', $image) -Capture }
                if (-not $want['backup']) {
                    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                    Note "No copy of your accounts kept, as asked."
                }
            }
        } else {
            if ($dockerGone) {
                Note "Docker Desktop is not on this PC any more, so nothing of EmberStorm is running."
            } else {
                Note "Docker is not available, so the containers were left alone."
                $stillRunning = $true
                $stopReason = 'Docker Desktop was not running.'
            }
        }
    }

    # Sleep and the lid as they were: the person's own setting, no
    # permission needed.
    $putBack = @()
    $powercfg = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\powercfg.exe'
    if ($stillRunning) {
        # EmberStorm still runs: its firewall rules, shortcuts and settings
        # stay with it, so phones keep reaching it and uninstalling again
        # finishes the job (the blind review: they were taken from a server
        # left running).
        $want['sleep'] = $false; $want['lid'] = $false; $want['signin'] = $false; $want['docker'] = $false
    }
    if ($want['sleep'] -and $offer.Contains('sleep')) {
        $null = Invoke-Native $powercfg @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE', "$sleepWas")
        if ($null -ne $changes['hibernateAc']) {
            $null = Invoke-Native $powercfg @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE', "$([int64]$changes['hibernateAc'])")
        }
        $putBack += 'sleeping when idle'
    }
    if ($want['lid'] -and $offer.Contains('lid')) {
        $null = Invoke-Native $powercfg @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', "$lidWas")
        $putBack += 'the lid setting'
    }
    if ($putBack.Count) { $null = Invoke-Native $powercfg @('/setactive', 'SCHEME_CURRENT') }

    # What needs an administrator, together, so Windows asks once: the
    # setup's own firewall rules (Windows' own rules and the network's
    # private setting are left as they are), signing in by itself turned off
    # and the Windows 11 setting it needed put back, and Docker Desktop
    # removed. Everything put in this script is a fixed string, a number or
    # a true/false.
    $rules = @()
    if (-not $stillRunning) { try {
        $rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            $_.DisplayName -eq $script:LanRuleName -or $_.DisplayName -like "$($script:DockerRuleName)*" })
    } catch { $rules = @() } }
    $signinBack = [bool]($want['signin'] -and $offer.Contains('signin'))
    $dockerOut = [bool]($want['docker'] -and $offer.Contains('docker') -and -not $stillRunning)
    $dockerUninstaller = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Docker\Docker\Docker Desktop Installer.exe'
    if ($dockerOut -and -not (Test-Path -LiteralPath $dockerUninstaller)) {
        $dockerOut = $false
        Note "Could not find Docker Desktop's uninstaller - remove it in Settings, Apps."
    }
    if ($rules.Count -or $signinBack -or $dockerOut) {
        $passwordLess = if ($changes['passwordLess'] -is [int] -or "$($changes['passwordLess'])" -match '^\d+$') { [int]$changes['passwordLess'] } elseif ($changes['passwordLess'] -eq 'absent') { -1 } else { 2 }
        $admin = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$env:PSModulePath = "`$PSHOME\Modules"
Get-NetFirewallRule -DisplayName '$($script:LanRuleName)' | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName '$($script:DockerRuleName)*' | Remove-NetFirewallRule
if (`$$(if ($signinBack) { 'true' } else { 'false' })) {
    `$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path `$winlogon -Name 'AutoAdminLogon' -Value '0'
    Remove-ItemProperty -Path `$winlogon -Name 'DefaultPassword'
    `$device = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
    if ($passwordLess -lt 0) { Remove-ItemProperty -Path `$device -Name 'DevicePasswordLessBuildVersion' }
    else { if (-not (Test-Path `$device)) { New-Item -Path `$device -Force | Out-Null }; Set-ItemProperty -Path `$device -Name 'DevicePasswordLessBuildVersion' -Value $passwordLess -Type DWord }
}
if (`$$(if ($dockerOut) { 'true' } else { 'false' })) {
    `$exe = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Docker\Docker\Docker Desktop Installer.exe'
    `$sig = Get-AuthenticodeSignature -LiteralPath `$exe
    if (`$sig.Status -eq 'Valid' -and "`$(`$sig.SignerCertificate.Subject)" -match '(^|, )O=Docker Inc,') {
        `$p = Start-Process -FilePath `$exe -ArgumentList 'uninstall', '--quiet' -PassThru
        `$p.WaitForExit()
    }
}
exit 0
"@
        if ($dockerOut) {
            Note "Removing Docker Desktop - Windows will ask for permission. This takes a minute or two."
            # Closed first: its uninstaller will not remove a Docker that runs.
            Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        } else {
            Note "Putting things back - Windows will ask for permission."
        }
        $code = Invoke-Elevated (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($admin)))
        if ($null -eq $code) {
            $dockerOut = $false
            $signinBack = $false
            $partly = $true
            Note "Windows' permission was not given, so the firewall rules, signing in by itself and Docker were left as they were."
        } else {
            if ($signinBack) { $putBack += 'asking for a password at sign-in' }
            if ($dockerOut -and (Get-DockerDesktopPath)) {
                $dockerOut = $false
                Note "Docker Desktop could not be removed - remove it in Settings, Apps."
            }
            # The folder this setup made for Docker's data on another drive:
            # gone with Docker when nothing is left in it, else named at the end.
            $dockerData = "$($changes['dockerData'])"
            if ($dockerOut -and $dockerData -match '^[A-Za-z]:\\EmberStorm-Docker$' -and (Test-Path -LiteralPath $dockerData)) {
                if (@(Get-ChildItem -LiteralPath $dockerData -Recurse -File -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $dockerData -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    $script:DockerDataLeft = $dockerData
                }
            }
        }
    }

    Step "Step 3 of 4 - Removing shortcuts"
    # Not stopped: the shortcuts stay with what still runs.
    if (-not $stillRunning) { Remove-Shortcuts }
    # Not stopped: the entry in Settings, Apps and the files it runs stay, so
    # uninstalling again can finish the job (they were removed, leaving no
    # way back to it - the bug review).
    if (-not $stillRunning -and -not $partly) { Remove-Item $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue }
    Good "Shortcuts removed."

    Step "Step 4 of 4 - Tidying up"
    # soundstorm-backup.json is deliberately not in this list. It is the only
    # thing here worth keeping, and the moment somebody wants it is after they
    # have already uninstalled.
    if (-not $stillRunning -and -not $partly) {
        foreach ($leftover in @('docker-compose.yml', '.env', 'soundstorm.ps1', 'tailscale-serve.json', 'docker-compose.yml.old', 'docker-compose.yml.new')) {
            Remove-Item -LiteralPath (Join-Path $Dir $leftover) -Force -ErrorAction SilentlyContinue
        }
        # The setup's own copy, its notes for carrying on after a restart and
        # its record of what it changed - kept while something it records is
        # still to be put back.
        Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'EmberStorm') -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  -----------------------------------------------------------"
    Write-Host "  Done." -ForegroundColor Green -NoNewline
    Write-Host " EmberStorm is gone."
    Write-Host ""
    if ($hasLibrary) {
        Write-Host "  Your media has been left exactly where it was:"
        Write-Host ""
        Write-Host "    $library"
        Write-Host ""
        Write-Host "  Delete that folder yourself if you want it gone. Nothing else"
        Write-Host "  will touch it."
    } else {
        Write-Host "  There was no media library to keep."
    }
    Write-Host ""
    if ($dockerOut) { Write-Host "  Docker Desktop was removed too." } elseif (Get-DockerDesktopPath) { Write-Host "  Docker Desktop was kept." }
    Write-Host ""
    if ($script:Gui) {
        $lines = @()
        if ($stillRunning) {
            $lines += @("EmberStorm could not be stopped: $stopReason Then uninstall again from Settings, Apps to finish - nothing else was changed.", '')
        }
        $backupFile = Join-Path $Dir 'soundstorm-backup.json'
        if ($backupSaved) {
            $lines += @('A copy of your accounts and the media servers'' passwords was saved, for if you install EmberStorm again:', "*$backupFile", '')
        } elseif ($want['backup'] -and -not $stillRunning -and $hadInstall) {
            $lines += @('A copy of your accounts could not be saved this time.', '')
        }
        if ($partly) {
            $lines += @('Windows did not give permission for some of it. Uninstall again from Settings, Apps to finish.', '')
        }
        if ($putBack.Count) {
            $lines += @("Put back as it was: $($putBack -join ', ').", '')
        }
        if ($hasLibrary) {
            $lines += @('Your media has been left exactly where it was:', "*$library", '', 'Delete that folder yourself if you want it gone. Nothing else will touch it.')
        }
        if ($dockerOut) {
            $lines += @('', 'Docker Desktop was removed too.')
            if ($script:DockerDataLeft) { $lines += @('Its data is still in this folder - delete it to get the space back:', "*$($script:DockerDataLeft)") }
        } elseif ((Get-DockerDesktopPath) -and $askedDocker -and $stillRunning) {
            $lines += @('', 'Docker Desktop was not removed, as EmberStorm could not be stopped first.')
        } elseif ((Get-DockerDesktopPath) -and $askedDocker) {
            $lines += @('', 'Docker Desktop could not be removed. It can be removed in Settings, Apps.')
        } elseif (Get-DockerDesktopPath) {
            $lines += @('', 'Docker Desktop was kept, as asked. It can be removed later in Settings, Apps.')
        }
        Set-GuiMessage $(if ($stillRunning) { 'Not quite finished' } else { 'Your media is kept' }) $lines $(if ($stillRunning) { 'Yellow' } else { 'Green' })
        Complete-Gui $(if ($stillRunning) { 'EmberStorm is partly removed' } else { 'EmberStorm is removed' }) 'Your music, films, books and photos were not touched.' ''
    }
    exit 0
}

# --- moving it to another computer ---------------------------------------------

# What a move carries besides the library: EmberStorm's own state (accounts,
# the passwords it made on every backend, favorites, playlists, positions,
# the install's name) and each backend's own database. Left out on purpose:
# the caches and downloaded models, which rebuild themselves, and Tailscale's
# node identity, which belongs to one machine. Kept in step with install.sh.
$MoveVolumes = @('soundstorm-state', 'navidrome-data', 'jellyfin-config', 'abs-config', 'abs-metadata',
    'immich-data', 'immich-db', 'storyteller-data', 'audiomuse-db')
# Settings that describe this computer and its network, worked out again on
# the new one.
$MoveLocal = '^SOUNDSTORM_(PORT|TLS_HOSTS|LIBRARY_PATH|LIBRARY_HINT|GATEWAY|UPNP_URL|NOT_HOME|INSTALLED|IMPORTING|IMPORTED)='
$MoveImage = 'alpine:3'
# The compose project, whose name prefixes every data volume. Always
# soundstorm; overridable only so a move can be rehearsed on a throwaway
# project without touching a real install's data.
$Project = if ($env:SOUNDSTORM_PROJECT) { $env:SOUNDSTORM_PROJECT } else { 'soundstorm' }

function Get-FolderSize([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [double]$sum } else { return 0 }
}

function Get-VolumeSize([string]$Volume) {
    $r = Invoke-Docker @('run', '--rm', '-v', "${Volume}:/v:ro", $MoveImage, 'du', '-sk', '/v') -Capture
    if ($r.ExitCode -ne 0) { return 0 }
    $kb = ($r.Output -split '\s+')[0]
    if ($kb -match '^\d+$') { return [double]$kb * 1024 } else { return 0 }
}

function Test-VolumeExists([string]$Volume) {
    return (Invoke-Docker @('volume', 'inspect', $Volume) -Capture).ExitCode -eq 0
}

# Copy-Folder copies a folder tree with robocopy, keeping the window alive,
# and returns the path of a log of what failed, or '' when nothing did.
function Copy-Folder([string]$From, [string]$To, [string]$ErrorLog) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    $process = Start-Process -FilePath 'robocopy.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        "`"$From`"", "`"$To`"", '/E', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', "/LOG:`"$ErrorLog`"")
    Wait-ProcessPumped $process | Out-Null
    # robocopy: 0-7 is success of one kind or another, 8 and up is failure.
    if ($process.ExitCode -lt 8) {
        Remove-Item -LiteralPath $ErrorLog -Force -ErrorAction SilentlyContinue
        return ''
    }
    return $ErrorLog
}

# Write-MoveLaunchers puts a one-click installer for each kind of computer in
# the move folder, each installing from the folder it sits in. The same two
# files install.sh writes.
function Write-MoveLaunchers([string]$Folder) {
    $sh = @(
        '#!/bin/sh',
        '# Installs EmberStorm on this computer from the move folder this file is in.',
        'here=$(cd "$(dirname "$0")" && pwd)',
        '# A fresh private file, not a fixed /tmp name another user could plant first.',
        't=$(mktemp) || exit 1',
        'trap ''rm -f "$t"'' EXIT',
        'curl -fsSL https://raw.githubusercontent.com/GabrielHollberg/emberstorm/main/install.sh -o "$t" &&',
        '	sh "$t" --import "$here"'
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $Folder 'install-here.sh'), "$sh`n", (New-Object Text.UTF8Encoding $false))
    $q = "'"
    $cmd = @(
        '@echo off',
        'rem Installs EmberStorm on this computer from the move folder this file is in.',
        'setlocal',
        'set "HERE=%~dp0"',
        'set "HERE=%HERE:~0,-1%"',
        'set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"',
        'set "SOUNDSTORM_SETUP_URL=https://raw.githubusercontent.com/GabrielHollberg/emberstorm/main/install.ps1"',
        ('start "" /min "%PS%" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$ProgressPreference = ' + $q + 'SilentlyContinue' + $q + '; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $f = Join-Path $env:TEMP ' + $q + 'soundstorm-install.ps1' + $q + '; try { Invoke-WebRequest -UseBasicParsing -Uri $env:SOUNDSTORM_SETUP_URL -OutFile $f } catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show(' + $q + 'EmberStorm could not download its installer. Check the internet connection and try again.' + $q + ', ' + $q + 'EmberStorm Setup' + $q + '); exit 1 }; $env:SOUNDSTORM_WINDOW = ' + $q + '1' + $q + '; $q = [char]34; Start-Process -FilePath (Join-Path $PSHOME ' + $q + 'powershell.exe' + $q + ') -WindowStyle Hidden -ArgumentList (' + $q + '-NoProfile -ExecutionPolicy Bypass -STA -File ' + $q + ' + $q + $f + $q + ' + $q + ' -Import ' + $q + ' + $q + $env:HERE + $q)"'),
        'exit /b 0'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $Folder 'Install EmberStorm here.cmd'), "$cmd`r`n", (New-Object Text.ASCIIEncoding))
}

# Select-MoveDestination asks where to put the move - usually an external
# drive - and whether to bring the media. Returns $null when canceled.
function Select-MoveDestination([double]$LibraryBytes) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $owner = New-TopmostOwner
    try {
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = 'Choose where to put EmberStorm for the move - an external drive, or a folder the new computer can reach. A folder called EmberStorm-move is made there.'
        $picker.ShowNewFolderButton = $true
        if ($picker.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $withLibrary = $true
        if ($LibraryBytes -gt 0) {
            $answer = [System.Windows.Forms.MessageBox]::Show($owner,
                "Copy your music, films, books and photos too? That is about $(Format-Size $LibraryBytes).`r`n`r`nChoose No if you are moving the media yourself - on the drive it is already on, say.",
                'EmberStorm - move to another computer',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) { return $null }
            $withLibrary = $answer -eq [System.Windows.Forms.DialogResult]::Yes
        }
        return [pscustomobject]@{ Path = $picker.SelectedPath; WithLibrary = $withLibrary }
    } finally {
        $owner.Dispose()
    }
}

# Export-Move packs this install into <Destination>\EmberStorm-move. EmberStorm
# is stopped while its data is copied - a database copied while it is being
# written may not open on the other side - and started again afterwards,
# whatever happened.
function Export-Move([string]$Destination, [bool]$WithLibrary) {
    if (-not (Test-Path (Join-Path $Dir 'docker-compose.yml'))) {
        Stop-With "  EmberStorm is not installed in $Dir, so there is nothing to move."
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        Stop-With "  $Destination does not exist. Choose a folder that does - an external drive, say."
    }
    $dest = Join-Path ([IO.Path]::GetFullPath($Destination)) 'EmberStorm-move'
    # One this setup began and did not finish (marked so): made again, so Try
    # again works (the blind review: it stopped on its own leftover).
    if (Test-Path -LiteralPath (Join-Path $dest 'unfinished.txt')) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $dest) {
        Stop-With "  $dest is already there.`n`n  Move or delete it first, so an older move is not mixed into this one."
    }
    Set-Location $Dir
    $library = Get-LibraryPath

    Step "Step 1 of 4 - Checking there is room"
    $need = 100MB
    if ($WithLibrary) { $need += Get-FolderSize $library }
    $volumes = @($MoveVolumes | Where-Object { Test-VolumeExists "${Project}_$_" })
    foreach ($v in $volumes) { $need += Get-VolumeSize "${Project}_$v" }
    $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($dest))).AvailableFreeSpace
    if ($free -lt $need) {
        Stop-With "  There is not enough room there: about $(Format-Size $need) is needed and $(Format-Size $free) is free.`n`n  Choose a bigger drive, or leave the media out and copy it yourself."
    }
    Good "About $(Format-Size $need) to copy, $(Format-Size $free) free."

    New-Item -ItemType Directory -Force -Path (Join-Path $dest 'volumes') | Out-Null
    [IO.File]::WriteAllText((Join-Path $dest 'unfinished.txt'), "An EmberStorm move that did not finish. Make it again.`r`n")
    # Passwords and keys go in it: this user's alone before anything is
    # written, not locked file by file after (the blind review). A drive with
    # no permissions at all (most USB sticks) is said plainly.
    if (-not (Protect-PrivateFolder $dest)) {
        Important "This drive cannot be locked to your account, and the move folder holds EmberStorm's passwords. Keep the drive safe, and delete the folder once the new computer is set up."
    }
    Step "Step 2 of 4 - Copying accounts, settings and the media servers' data"
    Note "EmberStorm is stopped while its data is copied, and started again after."
    Invoke-Docker @('compose', 'stop') -Capture | Out-Null
    try {
        foreach ($v in $volumes) {
            Note $v
            # tar in a container: the volume is Docker's, and only a container
            # can read it. Owners are kept as numbers, which each backend needs
            # to read its own files on the other side.
            $r = Invoke-Docker @('run', '--rm', '-v', "${Project}_${v}:/from:ro", '-v', "$(Join-Path $dest 'volumes'):/to",
                $MoveImage, 'tar', '-cf', "/to/$v.tar", '-C', '/from', '.') -Capture
            if ($r.ExitCode -ne 0) {
                # Started again before saying so: the error window waits for
                # the person, and the finally below runs only after it.
                Invoke-Docker @('compose', 'start') -Capture | Out-Null
                Stop-With "  Could not copy $v. EmberStorm has been started again, unchanged.`n`n  $($r.Output)"
            }
            # Every backend's admin password, the accounts' password hashes and
            # the certificate keys are in these: only this user, as settings.env
            # is (a security review found them open to anybody the drive is).
            Protect-SecretFile (Join-Path (Join-Path $dest 'volumes') "$v.tar")
        }
        # Plain line endings in everything the move writes: it may be read on
        # a Mac or Linux, where a carriage return becomes part of every value.
        $settings = Join-Path $dest 'settings.env'
        $kept = @(Get-Content -Encoding UTF8 (Join-Path $Dir '.env') | Where-Object { $_ -notmatch $MoveLocal })
        [IO.File]::WriteAllText($settings, (($kept -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
        Protect-SecretFile $settings

        Step "Step 3 of 4 - Copying your media"
        if ($WithLibrary -and (Test-Path $library)) {
            Note "This is the long part."
            $failed = Copy-Folder $library (Join-Path $dest 'library') (Join-Path $dest 'copy-errors.txt')
            if ($failed) {
                Important "Some files could not be copied. They are listed in $failed - copy those by hand."
            }
        } else {
            Note "Leaving the media out, as asked."
        }

        Write-MoveLaunchers $dest
        $manifest = @('format=1', "created=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))", 'from=Windows',
            "library=$(if (Test-Path (Join-Path $dest 'library')) { 'yes' } else { 'no' })")
        [IO.File]::WriteAllText((Join-Path $dest 'manifest.txt'), (($manifest -join "`n") + "`n"), (New-Object Text.ASCIIEncoding))
        Remove-Item -LiteralPath (Join-Path $dest 'unfinished.txt') -Force -ErrorAction SilentlyContinue
    } finally {
        Step "Step 4 of 4 - Starting EmberStorm again"
        Invoke-Docker @('compose', 'start') -Capture | Out-Null
    }

    $lines = @(
        'Everything is in:',
        "*  $dest",
        '',
        'On the new computer, copy the folder over, then:',
        '  Windows: double-click "Install EmberStorm here.cmd" inside it.',
        '  Mac or Linux: sh install-here.sh, inside it.',
        '',
        'Anything changed here from now on does not move. Once the new computer is',
        'working, uninstall EmberStorm here from Settings, Apps.'
    )
    if (-not (Test-Path (Join-Path $dest 'library'))) {
        $lines += @('', 'Your media was not included. Copy it to the new computer yourself:', "*  $library")
    }
    Callout 'Packed up' $lines 'Green'
    Start-Process explorer.exe -ArgumentList "`"$dest`""
    Complete-Gui 'EmberStorm is packed up' 'Copy the EmberStorm-move folder to the new computer and open it there.' ''
    exit 0
}

# Test-MoveFolder stops unless Path is a move folder this version can read.
function Test-MoveFolder([string]$Path) {
    $manifest = Join-Path $Path 'manifest.txt'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Stop-With "  $Path is not a EmberStorm move folder: it has no manifest.txt.`n`n  Point -Import at the EmberStorm-move folder made by the move."
    }
    if (-not (Select-String -LiteralPath $manifest -Pattern '^format=1$' -Quiet)) {
        Stop-With "  That move was made by a newer EmberStorm. Get the newest setup and try again."
    }
}

# Import-Settings carries the install's own settings across - setup code,
# secrets, https and remote access choices - on top of the fresh .env.
function Import-Settings([string]$Path) {
    $file = Join-Path $Path 'settings.env'
    if (-not (Test-Path -LiteralPath $file)) { return }
    foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $file) {
        # Only the install's own choices and secrets: a move folder on a stick
        # could otherwise set the image that runs, or the name service and
        # certificate authority it trusts (a security review).
        if ($line -match $MoveLocal -or $line -notmatch '^(SOUNDSTORM_(SETUP_CODE|REMOTE_ACCESS|TAILSCALE_AUTHKEY|TAILSCALE_HOSTNAME|TLS|AUDIOMUSE_DB_PASSWORD|IMMICH_DB_PASSWORD|STORYTELLER_SECRET|LOG_LEVEL)|TS_AUTHKEY)=') { continue }
        $key, $value = $line -split '=', 2
        # Written as .env has them, a $ as $$; Set-EnvSetting doubles it again.
        Set-EnvSetting $key ($value.Replace('$$', '$'))
    }
}

# Import-Volumes restores the data volumes. Refused where EmberStorm already
# has data: an import is for a computer it is new to.
function Import-Volumes([string]$Path) {
    # Brought in already by this import, which stopped later (a download, a
    # start): carried on from there rather than refused (the blind review).
    if ((Get-EnvSetting 'SOUNDSTORM_IMPORTED') -eq '1' -and (Test-VolumeExists "${Project}_soundstorm-state")) {
        Note "Using the accounts and data already brought in from the move."
        return
    }
    # Begun by this import and stopped part way: brought in again, over what
    # arrived. Anything else already here is somebody's data.
    if ((Get-EnvSetting 'SOUNDSTORM_IMPORTING') -ne '1' -and (Test-VolumeExists "${Project}_soundstorm-state")) {
        Stop-With "  This computer already has EmberStorm data, so importing would write over it.`n`n  Uninstall EmberStorm here first (Settings, Apps - your media is kept), then open the move again."
    }
    Set-EnvSetting 'SOUNDSTORM_IMPORTING' '1'
    foreach ($tar in Get-ChildItem -LiteralPath (Join-Path $Path 'volumes') -Filter '*.tar' -ErrorAction SilentlyContinue) {
        $v = $tar.BaseName
        if ($MoveVolumes -notcontains $v) { Note "Skipping $v, which this version does not know."; continue }
        Note $v
        # Labeled as compose labels its own, so compose adopts it.
        $made = Invoke-Docker @('volume', 'create', '--label', "com.docker.compose.project=$Project",
            '--label', "com.docker.compose.volume=$v", "${Project}_$v") -Capture
        if ($made.ExitCode -ne 0) { Stop-With "  Could not create the $v volume.`n`n  $($made.Output)" }
        $r = Invoke-Docker @('run', '--rm', '-v', "${Project}_${v}:/to", '-v', "$(Join-Path $Path 'volumes'):/from:ro",
            $MoveImage, 'sh', '-c', "cd /to && tar -xf /from/$v.tar") -Capture
        if ($r.ExitCode -ne 0) { Stop-With "  Could not restore $v from the move folder.`n`n  $($r.Output)" }
    }
    Set-EnvSetting 'SOUNDSTORM_IMPORTED' '1'
}

if ($Export -or $Move) {
    if ($Move -and -not $Export) {
        $choice = Select-MoveDestination (Get-FolderSize (Get-LibraryPath))
        if (-not $choice) { exit 0 }
        $Export = $choice.Path
        if (-not $choice.WithLibrary) { $NoLibrary = [switch]$true }
    }
    if ($env:SOUNDSTORM_WINDOW -eq '1' -and $script:WindowWanted) {
        try {
            New-SetupWindow 'Moving EmberStorm to another computer' `
                'Packing up your accounts, settings and media into one folder to take to the new computer.' `
                @('Checking there is room', 'Copying accounts and settings', 'Copying your media', 'Starting EmberStorm again')
        } catch {
            $script:Gui = $null
        }
    }
    Initialize-Docker
    Export-Move $Export (-not $NoLibrary)
}

# --- opening an install that is already here ----------------------------------

if ($Launch) {
    if (-not (Test-Path (Join-Path $Dir 'docker-compose.yml'))) {
        Stop-With "  EmberStorm is not installed in $Dir. Run the setup again."
    }
    Set-Location $Dir
    Initialize-Docker
    # A laptop that moved to another network: point the secure name at where
    # it is now, and the port opening at the router it is behind now. compose
    # sees the changed .env and recreates the container.
    $null = Update-LanAddress
    $null = Update-RouterSettings -Quick
    if ((Invoke-DockerBounded @('compose', 'up', '-d')) -ne 0) {
        Save-EmberStormLog
        Stop-With "  EmberStorm would not start.`n`n$(Get-HelpAdvice)"
    }
    $port = Get-InstalledPort
    $url = "$(Get-InstalledScheme)://localhost:$port"
    Wait-ForEmberStorm $url
    # On a network Windows treats as public, other devices are kept out: ask.
    Confirm-LanOnLaunch
    # At startup there is nobody watching yet, so the browser stays shut; the
    # desktop icon is what opens it.
    if (-not $NoBrowser) {
        # With the setup code while nobody has signed up yet. Somebody who
        # closed the tab setup opened reaches for this icon next, and without
        # the code the first screen asks for one they have no idea where to
        # find.
        $open = $url
        $code = Get-EnvSetting 'SOUNDSTORM_SETUP_CODE'
        if ($code -and (Get-HasAccount $url) -ne $true) { $open = "$url/?setup=$code" }
        Start-Process $open
    }
    exit 0
}

# --- installing -----------------------------------------------------------------

# Run now, by hand or after a restart: nothing is to start again at the next
# sign-in unless this run arranges it.
if (-not $Launch) { Clear-Resume }

$firstInstall = -not (Test-InstalledHere)
try { [IO.File]::WriteAllText($script:SetupLog, '') } catch { }
if ($env:SOUNDSTORM_WINDOW -eq '1' -and $script:WindowWanted) {
    try {
        if ($firstInstall) {
            New-SetupWindow 'Setting up EmberStorm' `
                'This sets everything up by itself. The first time takes about 10 to 30 minutes, mostly downloading. You can use the computer while it works.' `
                @('Getting Docker ready', 'Preparing the EmberStorm folder', 'Downloading the media servers', 'Starting EmberStorm')
        } else {
            New-SetupWindow 'Updating EmberStorm' `
                'Your library, accounts and settings are kept.' `
                @('Getting Docker ready', 'Preparing the EmberStorm folder', 'Checking for a newer version', 'Starting EmberStorm')
        }
    } catch {
        # A window that cannot be built must not leave a hidden setup running
        # with nothing on screen: start again, visibly, in a console.
        $script:Gui = $null
        $env:SOUNDSTORM_CONSOLE = '1'
        if ($script:SetupMutex) { try { $script:SetupMutex.ReleaseMutex() } catch { } }
        Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"") +
                (ConvertTo-ArgumentList $PSBoundParameters))
        exit 1
    }
}

Write-Host ""
Write-Host "  EmberStorm" -ForegroundColor White -NoNewline
Write-Host " - all your music, films, books and audiobooks in one place"
Write-Host "  -----------------------------------------------------------"

# Said before anything happens, because the two questions somebody has from
# here on are "is it still working?" and "what am I supposed to do?" - and on a
# first install the honest answer to the first is "for a while yet".
Write-Host ""
if ($firstInstall) {
    Write-Host "  This sets everything up by itself, in 4 steps. The first time takes" -ForegroundColor White
    Write-Host "  about 10 to 30 minutes, mostly downloading." -ForegroundColor White
    Write-Host ""
    Write-Host "  Keep this window open. It tells you when it is finished and exactly" -ForegroundColor Yellow
    Write-Host "  what to do next. You can use the computer while it works." -ForegroundColor Yellow
} else {
    Write-Host "  Updating EmberStorm. Your library, accounts and settings are kept." -ForegroundColor White
    Write-Host "  Keep this window open until it says it is finished." -ForegroundColor Yellow
}

# The questions first, on a first install, while somebody is at the screen:
# installing Docker takes ten minutes and more, and a person who walked away
# then came back to the setup waiting on a question (a review, 2026-10-09).
# Where the library goes, the home network, keeping it available, and room
# for the download - then nothing more is asked. Not when EmberStorm is
# already installed in another folder: step 2 says so, and questions first
# would be questions for nothing.
$installedElsewhere = $false
if ($firstInstall -and (Get-Command docker -ErrorAction SilentlyContinue) -and (Test-DockerRunning)) {
    $other = Get-ExistingInstallPath
    $installedElsewhere = [bool]($other -and $other -ne $Dir)
}
if ($firstInstall -and -not $installedElsewhere -and $env:EMBERSTORM_ASKED -eq '1') {
    # Carrying on after a restart: everything was asked before it.
    $script:QuestionsAsked = $true
    $script:LibraryAsked = $true
    $lan = Get-LanAddress
    $lanAccess = if ($env:EMBERSTORM_LAN) { $env:EMBERSTORM_LAN } else { 'unknown' }
    # Docker installed before the restart was this setup's.
    if ($env:EMBERSTORM_DOCKER_OURS -eq '1') { Save-SetupChange 'docker' $true }
    # The room check is not run again: part of the download may already be
    # in, and it would count against itself.
    Note "Carrying on where the setup stopped."
    if ($script:Gui) { $script:Gui.Sub.Text = 'Carrying on where the setup stopped - the rest runs by itself.' }
} elseif ($firstInstall -and -not $installedElsewhere) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue) -and -not (Test-Virtualization)) { Stop-ForVirtualization }
    if (-not $Library -and -not (Get-EnvSetting 'SOUNDSTORM_LIBRARY_PATH')) {
        $choice = Select-LibraryLocation (Get-LibraryPath)
        if ($choice) { $Library = $choice }
        $script:LibraryAsked = $true
    }
    # Room where things will really go, once the library's drive is known
    # (Docker's data goes with it). Docker Desktop itself wants about 5 GB
    # more, when it is still to come.
    Test-DownloadRoom $(if (Get-Command docker -ErrorAction SilentlyContinue) { 20GB } else { 25GB })
    # The port it will most likely have (step 2 picks it again the same way;
    # a different one is opened after it starts).
    $earlyPort = $FirstPort
    while (-not (Test-PortFree $earlyPort) -and $earlyPort -lt $FirstPort + 20) { $earlyPort++ }
    $lan = Get-LanAddress
    $lanAccess = Set-LanAccessRemembered $lan $earlyPort
    Confirm-AlwaysOn
    $script:QuestionsAsked = $true
    Note "That's all the questions. Windows may still ask for permission once or twice - click Yes."
    # Where it stays in sight: the status line is cleared by the next step.
    if ($script:Gui) { $script:Gui.Sub.Text = "That's all the questions - the rest runs by itself. Windows may still ask for permission once or twice: its question names ""Windows PowerShell"", which is this setup. Click Yes." }
}

Step "Step 1 of 4 - Getting Docker ready"
Initialize-Docker
Write-Host "    $((Invoke-Native 'docker' @('--version')).Output)"
Good "Docker is ready."

Step "Step 2 of 4 - Preparing the EmberStorm folder"
Note $Dir

# The compose project name is fixed, so a second install in a second folder
# adopts the first one's containers and then points at an empty library.
$previous = Get-ExistingInstallPath
# Split out rather than written as one long condition: PowerShell 5.1 will not
# take a line break before an operator inside an if, and the one-line version
# is unreadable.
$installedHere = Test-Path (Join-Path $Dir 'docker-compose.yml')
$elsewhere = $previous -and ($previous -ne $Dir) -and (-not $installedHere)
if ($elsewhere -and $env:SOUNDSTORM_FORCE -ne '1') {
    # The address as well as the folder. "Use the one that is already there"
    # is not an instruction if it does not say how, and somebody who ran this
    # a second time is quite likely to have run it because they could not
    # remember where it was.
    $existing = Get-InstalledURL $previous
    Stop-With @"
  EmberStorm is already installed, in another folder:

    $previous

  It should be running. Open it here:

    $existing

  Installing it here as well would not give you a second copy - both folders
  drive the same containers, and this one would point at an empty library, so
  your media would look like it had vanished.

  To install it here instead, remove the other copy first:

    1. Open Settings, then Apps, then Installed apps.
    2. Find EmberStorm and choose Uninstall. Your music, films and books
       are never deleted - it only removes the app.
    3. Run this setup again.

  If EmberStorm is not in that list, it was set up by hand - ask whoever
  did that to remove it.
"@
}

$insideProfile = $Dir.TrimEnd('\').StartsWith($env:USERPROFILE.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
$dirIsNew = -not (Test-Path -LiteralPath $Dir)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
# Private from the moment it exists: another account watching the drive
# could otherwise put a file in it before the checks below (the blind
# review).
if ($dirIsNew -and -not $insideProfile) { $null = Protect-PrivateFolder $Dir }
Set-Location $Dir



if (-not $insideProfile) {
    try {
        $format = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Dir))).DriveFormat
        if ($format -notin @('NTFS', 'ReFS')) {
            Important "The drive $([IO.Path]::GetPathRoot($Dir)) ($format) cannot keep files private to your account, so any account on this PC could change EmberStorm's files there. A folder on an NTFS drive is safer."
        }
    } catch { }
    # Any file at the top that another account owns is refused, not only the
    # names the setup writes.
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-OwnedByMe $file.FullName)) {
            Stop-With "  $($file.FullName) belongs to another account on this PC, so EmberStorm will not use this folder.`n`n  Choose a folder of your own, or remove that file and run the setup again."
        }
    }
    foreach ($kept in @('.', 'docker-compose.yml', 'docker-compose.yml.new', 'docker-compose.yml.old', 'docker-compose.override.yml', 'compose.yaml', 'compose.yml', '.env', 'soundstorm.ps1', 'tailscale-serve.json', 'soundstorm-backup.json')) {
        $path = Join-Path $Dir $kept
        if ((Test-Path -LiteralPath $path) -and -not (Test-OwnedByMe $path)) {
            Stop-With "  $path belongs to another account on this PC, so EmberStorm will not use it.`n`n  Choose a folder of your own, or remove it and run the setup again."
        }
    }
    # And nobody else may add to it: an empty file another account made under
    # a name the setup writes next stayed theirs once written over (the
    # security review). Once, then kept.
    if (Test-OthersCanWrite $Dir) {
        Note "Making the EmberStorm folder private to your account."
        if (-not (Protect-PrivateFolder $Dir)) { Note "Could not change the folder's permissions." }
    }
}

if ($Import) {
    try { $Import = [IO.Path]::GetFullPath($Import) } catch { Stop-With "  Could not open $Import." }
    Test-MoveFolder $Import
    if (Test-InstalledHere) {
        Stop-With "  EmberStorm is already installed in $Dir, so importing would write over it.`n`n  Uninstall it first (Settings, Apps - your media is kept), then open the move again."
    }
}

$upgrade = (Test-InstalledHere) -and $env:SOUNDSTORM_FORCE -ne '1'
if ($upgrade) {
    Note "Already installed here - updating it instead."
    # The current compose file too: an update used to keep the one it was
    # installed with, so containers added since and the hardening in it
    # (private networks, pinned versions) never reached an install (the
    # blind security review). A failed download keeps the one there.
    try {
        Invoke-WebRequest -Uri $ComposeUrl -OutFile 'docker-compose.yml.new' -UseBasicParsing
        if ((Get-Item 'docker-compose.yml.new').Length -gt 0) {
            # The one it had, kept until the new versions are downloaded: its
            # images pinned, the new file named versions not yet here, and a
            # download that failed then could start nothing (a review).
            Copy-Item -Force -LiteralPath 'docker-compose.yml' 'docker-compose.yml.old'
            Move-Item -Force 'docker-compose.yml.new' 'docker-compose.yml'
            Note "Got the list of the newest versions."
        }
    } catch {
        Remove-Item -Force -ErrorAction SilentlyContinue 'docker-compose.yml.new'
        Note "Could not download the current docker-compose.yml - keeping the one here."
    }
} else {
    try {
        # To a temporary name first, so a failed download cannot leave a
        # working install with half a compose file in it.
        Invoke-WebRequest -Uri $ComposeUrl -OutFile 'docker-compose.yml.new' -UseBasicParsing
        Move-Item -Force 'docker-compose.yml.new' 'docker-compose.yml'
    } catch {
        Stop-With "  Could not download EmberStorm from`n`n    $ComposeUrl`n`n  Check the internet connection and try again."
    }
}

# A copy of this script lives beside the install, so the desktop shortcut has
# something to run and updating later needs no web address.
try {
    Invoke-WebRequest -Uri $ScriptUrl -OutFile 'soundstorm.ps1' -UseBasicParsing
} catch {
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Copy-Item $PSCommandPath 'soundstorm.ps1' -Force
    }
}

# Always, whether or not Tailscale is wanted. compose bind-mounts this file,
# and Docker's answer to a bind mount whose source is missing is to create a
# *directory* with that name - after which the container fails in a way that
# reads like a Tailscale problem rather than a missing file.
if (-not (Test-Path (Join-Path $Dir 'tailscale-serve.json'))) { Write-ServeConfig }

if ($upgrade) {
    $port = Get-InstalledPort
} else {
    $port = $FirstPort
    while (-not (Test-PortFree $port)) {
        $port++
        if ($port -gt $FirstPort + 20) {
            Stop-With "  Ports $FirstPort to $port are all in use on this PC.`n`n  Restart the PC and try again. If it happens again, send the log file (Show log file, below) to whoever helps you with EmberStorm."
        }
    }
    if ($port -ne $FirstPort) { Note "Port $FirstPort was busy, using $port." }

    # Compose reads .env from beside the compose file, so these stick.
    #
    # The LAN address is written even though TLS is off, because it is needed
    # the moment somebody turns TLS on and it cannot be worked out then: the
    # server is in a container and sees only the container's addresses. Better
    # recorded now, while the machine that knows is the one running.
    $lan = Get-LanAddress
    if (Test-Path -LiteralPath (Join-Path $Dir '.env')) {
        # Kept, not written afresh: it holds the setup code and every secret
        # (SOUNDSTORM_FORCE, or a first install stopped part way).
        Set-EnvSetting 'SOUNDSTORM_PORT' "$port"
        if ($lan -and -not (Get-EnvSetting 'SOUNDSTORM_TLS_HOSTS')) { Set-EnvSetting 'SOUNDSTORM_TLS_HOSTS' $lan }
    } else {
        $lines = @("SOUNDSTORM_PORT=$port")
        if ($lan) { $lines += "SOUNDSTORM_TLS_HOSTS=$lan" }
        [IO.File]::WriteAllLines((Join-Path $Dir '.env'), [string[]]$lines, (New-Object Text.UTF8Encoding $false))
    }
    Protect-SecretFile (Join-Path $Dir '.env')
}

# A "not my home network" answered before the settings file existed.
if ($script:PendingNotHome) {
    $declined = @((Get-EnvSetting 'SOUNDSTORM_NOT_HOME') -split '\|' | Where-Object { $_ })
    Set-EnvSetting 'SOUNDSTORM_NOT_HOME' ((@($declined + $script:PendingNotHome) | Select-Object -Last 20) -join '|')
}

# After the port, so that on a fresh install this amends the file just written
# rather than being overwritten by it.
#
# Auto is the default: a real certificate for a <id>.home.soundstorm.dev name,
# with plain http still answering on the same port. It is written for a fresh
# install and for an existing one that never chose - an absent line meant
# "off" only because off was the default then. A choice somebody made (off,
# self-signed, file) is left alone.
$tlsNow = Get-EnvSetting 'SOUNDSTORM_TLS'
if ($Https -or ($NoHttps -eq $false -and -not $tlsNow)) {
    # Auto points its name at the LAN address, and only this machine can say
    # what that is - the server sees the container's address, not the PC's.
    # An install from before .env carried this line has to be topped up here.
    if (-not (Get-EnvSetting 'SOUNDSTORM_TLS_HOSTS')) {
        $lan = Get-LanAddress
        if ($lan) { Set-EnvSetting 'SOUNDSTORM_TLS_HOSTS' $lan }
    }
    Set-EnvSetting 'SOUNDSTORM_TLS' 'auto'
    if ($Https -or $upgrade) { Note "Turning on secure connections." }
} elseif ($NoHttps) {
    Set-EnvSetting 'SOUNDSTORM_TLS' 'off'
    Note "Turning https off."
}
if (Update-LanAddress) { Note "This PC's network address has changed; EmberStorm will use the new one." }
$tlsMode = Get-EnvSetting 'SOUNDSTORM_TLS'

# Remote access is off unless -Remote is given, and it can be turned on later
# from inside the app - so this only ever writes when the flag is present, and
# an existing choice (the app's, or a previous run's) is left alone otherwise.
# It needs auto https to have a real certificate; the toggle in the app is
# hidden without one, and the server refuses the change, so the flag just seeds
# the default that toggle starts from.
if ($Remote) {
    Set-EnvSetting 'SOUNDSTORM_REMOTE_ACCESS' 'on'
    Note "Turning on access from the internet."
    if ($tlsMode -ne 'auto') {
        Write-Host "  Note: reaching it from the internet needs https on." -ForegroundColor Yellow
    }
} elseif ($NoRemote) {
    Set-EnvSetting 'SOUNDSTORM_REMOTE_ACCESS' 'off'
    Note "Keeping it to the home network."
}

# The router address and its UPnP URL, for opening the port automatically when
# remote access is on. Written whether or not remote access is on yet, for the
# same reason as the LAN address: by the time somebody turns it on from inside
# the app, nothing on the host is running to work it out. Kept current on every
# run, not only written once - see Update-RouterSettings.
$null = Update-RouterSettings

# A move brings the install's own settings - setup code, secrets, choices -
# on top of the fresh file, before anything below reads them.
if ($Import) {
    Import-Settings $Import
    # The move's own choice of https, not this computer's default.
    $tlsMode = Get-EnvSetting 'SOUNDSTORM_TLS'
}

# The first sign-up needs a setup code, so that whoever reaches the port
# before the owner does - from the internet, once it faces it - cannot claim
# the server. It goes into the address the browser is opened at below, so
# nobody installing ever sees it. Kept once written: a second run must open
# the page with the code the server already has.
$setupCode = Get-EnvSetting 'SOUNDSTORM_SETUP_CODE'
if (-not $setupCode) {
    $bytes = New-Object byte[] 10
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $setupCode = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Set-EnvSetting 'SOUNDSTORM_SETUP_CODE' $setupCode
}

# Every run, not only when something above was written: an install from before
# this existed has a .env with its folder's permissions, and running the
# installer again - which is how updating works - is what fixes it.
Protect-SecretFile (Join-Path $Dir '.env')
# And what runs: the saved script (run at every sign-in by the startup
# shortcut) and the compose files. A folder at a drive root, C:\EmberStorm,
# lets every account on the PC change files in it, and a changed script or
# compose file would run as this user, or as root in Docker (a security
# review).
foreach ($runs in 'soundstorm.ps1', 'docker-compose.yml', 'tailscale-serve.json') {
    $p = Join-Path $Dir $runs
    if (Test-Path -LiteralPath $p) { Protect-SecretFile $p }
}

# Where the library lives. Beside the install unless -Library says otherwise,
# which is how it goes on an external drive. Compose mounts every shelf from
# the same setting, so they all follow.
#
# Existing media is never moved for anybody: tens of gigabytes shifted by a
# script is exactly the operation that should not fail halfway. Somebody moving
# the library is told where the old files are, and how.
#
# On a first install with no -Library, the person is asked. Never on an update:
# the library already has media in it by then, and a question whose honest
# answer is "move every file yourself" is not one to ask on every update.
if (-not $Library -and $firstInstall -and -not $script:LibraryAsked -and -not (Get-EnvSetting 'SOUNDSTORM_LIBRARY_PATH')) {
    $choice = Select-LibraryLocation (Get-LibraryPath)
    if ($choice) { $Library = $choice }
} elseif (-not $Library -and $ChooseLibrary) {
    $choice = Select-LibraryLocation (Get-LibraryPath) `
        'Choose where EmberStorm should keep your music, films and books from now on. Your files are not moved - you will be shown both folders at the end.'
    if ($choice) {
        $Library = $choice
    } else {
        Note "Keeping the library where it is."
    }
}
$movedFrom = ''
if ($Library) {
    try {
        $full = [IO.Path]::GetFullPath($Library)
        $script:libraryWasThere = Test-Path -LiteralPath $full
        New-Item -ItemType Directory -Force -Path $full -ErrorAction Stop | Out-Null
    } catch {
        Stop-With "  Could not use $Library for the library: $($_.Exception.Message)`n`n  Check the drive is connected, then run the setup again."
    }
    # Docker's settings file cuts a value at " #" and stops at a starting
    # quote: the shelves were mounted from an empty folder beside the media
    # (a review, 2026-10-09).
    if ($full -match ' #' -or $full -match "^['""]") {
        Stop-With "  The folder $full cannot be used for the library: its name has "" #"" in it, or starts with a quote.`n`n  Rename it, then run the setup again."
    }
    $previous = Get-LibraryPath
    Set-EnvSetting 'SOUNDSTORM_LIBRARY_PATH' ($full -replace '\\', '/')
    # What the app shows as the library's location: the path a person would
    # type into Explorer, not the one Docker is given.
    Set-EnvSetting 'SOUNDSTORM_LIBRARY_HINT' $full
    Note "Keeping the library in $full"
    if ($previous -ne $full -and (Test-Path $previous) -and
        (Get-ChildItem $previous -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'README.txt' } | Select-Object -First 1)) {
        Write-Host ""
        Write-Host "  Your existing media is still in $previous." -ForegroundColor Yellow
        Write-Host "  Both folders open when the setup finishes, so it can be dragged across." -ForegroundColor Gray
        Write-Host ""
        $movedFrom = $previous
    }
}
$libraryPath = Get-LibraryPath
# Before the folder was made above, when it was chosen here.
$libraryIsNew = if ($null -ne $script:libraryWasThere) { -not $script:libraryWasThere } else { -not (Test-Path -LiteralPath $libraryPath) }

foreach ($folder in 'music', 'movies', 'tv', 'audiobooks', 'ebooks', 'documents', 'pictures') {
    New-Item -ItemType Directory -Force -Path (Join-Path $libraryPath $folder) | Out-Null
}
# Made now, outside the person's own folder (another drive): theirs alone, as
# a drive root lets every account on the PC in - members' private photos
# included (the security review). Only when made now: an existing library may
# be shared on purpose, and changing a big one's permissions takes a while.
$libraryInProfile = $libraryPath.TrimEnd('\').StartsWith($env:USERPROFILE.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
if (-not $libraryInProfile) {
    # Another account's folder is not used: one made ahead under the name the
    # setup suggests (D:\EmberStorm) would have kept its way in (the blind
    # review).
    if (-not (Test-OwnedByMe $libraryPath)) {
        Stop-With "  $libraryPath belongs to another account on this PC, so EmberStorm will not keep your library there.`n`n  Choose a folder of your own, or remove that one and run the setup again."
    }
    # Made now, or still empty: theirs alone. An existing library with media
    # in it is left as it is - it may be shared on purpose, and changing a big
    # one's permissions takes a while.
    $empty = -not (Get-ChildItem -LiteralPath $libraryPath -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (($libraryIsNew -or $empty) -and (Test-OthersCanWrite $libraryPath)) {
        if (-not (Protect-PrivateFolder $libraryPath)) { Note "Could not make the library folder private to your account." }
    }
}

# A move: the media first, then the data, and only then does anything start -
# a backend started on empty volumes would set itself up afresh.
if ($Import) {
    if (Test-Path (Join-Path $Import 'library')) {
        Note "Copying your media from the move folder. This is the long part."
        $failed = Copy-Folder (Join-Path $Import 'library') $libraryPath (Join-Path $Dir 'move-copy-errors.txt')
        if ($failed) { Important "Some files could not be copied. They are listed in $failed." }
        if (Test-Path (Join-Path $Import 'windows-name-problems.txt')) {
            Important "Some files have names Windows does not allow, and could not come across."
            Important "They are listed in $(Join-Path $Import 'windows-name-problems.txt')."
        }
    }
    Note "Restoring accounts, settings and the media servers' data."
    Import-Volumes $Import
}
$scheme = Get-InstalledScheme

# Remote access. Off unless asked for, and it stays a separate decision from
# -Https: one is about the wifi at home, the other about being away from it.
if ($Tailscale) {
    $key = $AuthKey
    if (-not $key) { $key = Get-EnvSetting 'SOUNDSTORM_TAILSCALE_AUTHKEY' }
    if (-not $key) {
        # Only on a request somebody made - the Set up Tailscale shortcut, or
        # -Tailscale typed. A double-click install never reaches it.
        Note "A window has opened to set up Tailscale."
        try {
            $key = Show-TailscaleDialog
        } catch {
            Write-Host ""
            Write-Host "  Reaching EmberStorm from outside the house needs a Tailscale account."
            Write-Host "  It is free for personal use and takes about two minutes."
            Write-Host ""
            Write-Host "    1. Sign up at https://tailscale.com"
            Write-Host "    2. Open the admin console, Settings, then Keys"
            Write-Host "    3. Generate an auth key and copy it"
            Write-Host ""
            $key = "$(Read-Text 'Paste the Tailscale auth key here' 'EmberStorm - Tailscale')".Trim()
        }
    }
    if ($key) {
        Set-EnvSetting 'SOUNDSTORM_TAILSCALE_AUTHKEY' $key
        Write-ServeConfig
        Note "Tailscale will be started with EmberStorm."
    } else {
        # Not an error: EmberStorm works exactly as before without it, and
        # stopping the whole update over a canceled window would be.
        Note "Tailscale was not set up. EmberStorm works on your home network as before."
        Note "To set it up later, open Set up Tailscale from the Start menu."
    }
} elseif ($NoTailscale) {
    Set-EnvSetting 'SOUNDSTORM_TAILSCALE_AUTHKEY' ''
    Note "Turning off remote access. EmberStorm stays on this network."
}

# Whether the profile is wanted at all, which outlives this run: somebody who
# set it up in January should still get it after an upgrade in June.
$useTailscale = $false
if (-not $NoTailscale) {
    $useTailscale = [bool](Get-EnvSetting 'SOUNDSTORM_TAILSCALE_AUTHKEY')
}
$composeArgs = @()
if ($useTailscale) { $composeArgs = @('--profile', 'tailscale') }

# Asked before the long download, not after it: people are at the screen
# now, and were not twenty minutes later. Opening the network also gives
# Docker's own firewall rules ahead of its first start, so Windows' "allow
# Docker Desktop Backend?" alert never appears (2026-10-09).
# (Asked before Step 1 on a first install; here for an update.)
if (-not $script:QuestionsAsked) {
    $lan = Get-LanAddress
    $lanAccess = Set-LanAccessRemembered $lan ([int]$port)
    # And with it, keeping EmberStorm reachable - the questions together,
    # then nothing more is asked.
    if (-not $upgrade) { Confirm-AlwaysOn }
}

# Room for the download, on the drive Docker keeps it on (its disk lives in
# the person's own folder, on C: unless moved): a full drive failed part way
# with an error from Docker that nobody could read.
if (-not $upgrade -and -not $script:QuestionsAsked) { Test-DownloadRoom }

if ($upgrade) {
    Step "Step 3 of 4 - Checking for a newer version"
} else {
    Step "Step 3 of 4 - Downloading the media servers"
    Note "About 8GB to download - the long part. Leave this window open; you can use the computer meanwhile."
}
# Shown rather than captured: this is the part that takes minutes, and a
# silent window is how somebody decides it has hung.
#
# A registry that sheds load answers "toomanyrequests" - Docker Hub and ghcr
# both do, and eight images pulled at once is exactly what trips it. That is
# not the internet connection, and telling somebody to check theirs sends them
# the wrong way. So a failed pull is retried after a wait, which is what the
# registry asked for; everything already downloaded is kept between tries.
$pullWaits = @(30, 60, 120)
$pull = $null
for ($attempt = 0; $attempt -le $pullWaits.Count; $attempt++) {
    $pull = Invoke-Docker (@('compose') + $composeArgs + @('pull')) -Calm
    if ($pull.ExitCode -eq 0 -or $attempt -eq $pullWaits.Count) { break }
    $wait = $pullWaits[$attempt]
    if ($pull.Output -match 'toomanyrequests|too many requests|rate limit|\b429\b') {
        Important "The download server is busy and asked us to slow down."
    } else {
        Important "The download stopped part way."
    }
    Note "Trying again in $wait seconds - nothing already downloaded is lost."
    Start-Sleep -Seconds $wait
}
$rateLimited = $pull.Output -match 'toomanyrequests|too many requests|rate limit|\b429\b'
if ($pull.ExitCode -ne 0 -and $upgrade) {
    # An update that cannot download is not a broken install: the version
    # already here still works, so start that rather than stopping - with the
    # compose file that names it.
    if (Test-Path -LiteralPath 'docker-compose.yml.old') {
        Move-Item -Force -LiteralPath 'docker-compose.yml.old' 'docker-compose.yml'
    }
    Important "Could not check for a newer version right now."
    Note "Starting the version you already have. Run 'Update EmberStorm' again later."
} elseif ($pull.ExitCode -ne 0 -and $rateLimited) {
    Stop-With "  The download server is limiting how fast it hands out downloads.`n  Nothing is wrong with this PC or your internet connection.`n`n  Wait about half an hour and run the setup again - anything already`n  downloaded is kept."
} elseif ($pull.ExitCode -ne 0 -and $pull.Output -match 'no space left on device|not enough space|disk is full|There is not enough space') {
    Stop-With "  The drive Docker keeps its downloads on is full.`n`n  Free some space on it - Settings, System, Storage shows what is using it -`n  then run the setup again. Anything already downloaded is kept."
} elseif ($pull.ExitCode -ne 0) {
    Stop-With "  Could not download the media servers. That is almost always the`n  internet connection. Try again - anything already downloaded is kept."
}

Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath 'docker-compose.yml.old'
Step "Step 4 of 4 - Starting EmberStorm"
if ($firstInstall -and -not (Test-DockerRulesReady) -and $lanAccess -notin @('public', 'refused', 'domain')) {
    # The dialog appears the moment the port is first published, i.e. during
    # the next command, and its default answer is the one that shuts phones
    # out on a network Windows thinks is public.
    Callout 'Windows may ask about the firewall' @(
        'A "Windows Security Alert" may appear for "Docker Desktop Backend".',
        '*Click "Allow access".',
        '',
        'That is what lets your phone and TV reach EmberStorm. If you clicked',
        'Cancel by mistake, carry on - this setup checks it in a moment.'
    ) 'Cyan'
}
$start = Invoke-Docker (@('compose') + $composeArgs + @('up', '-d')) -Capture
if ($start.ExitCode -ne 0) {
    Write-Host $start.Output
    if ($start.Output -match 'already allocated|address already in use|forbidden by its access permissions') {
        Stop-With "  Port $port is already being used by another program on this PC.`n`n  Restart the PC and try again. If it happens again, send the log file (Show log file, below) to whoever helps you with EmberStorm."
    }
    Save-EmberStormLog
    Stop-With "  EmberStorm would not start.`n`n$(Get-HelpAdvice)"
}

$url = "${scheme}://localhost:$port"
Wait-ForEmberStorm $url
# Checked again now it is running: Windows' firewall alert can still appear as
# it starts (Docker installed somewhere unusual, a rule from an older install),
# and Cancel there shuts phones out though the check before said ready.
if ($lan -and $lanAccess -eq 'ready' -and -not (Test-LanAccessReady ([int]$port))) {
    $lanAccess = Set-LanAccess $lan ([int]$port)
}
# Started and answering: installed, from now on an update.
Set-EnvSetting 'SOUNDSTORM_INSTALLED' '1'
# An import is over once it has started: the marks that let it carry on go.
if ((Get-EnvSetting 'SOUNDSTORM_IMPORTING') -eq '1') {
    Set-EnvSetting 'SOUNDSTORM_IMPORTING' ''
    Set-EnvSetting 'SOUNDSTORM_IMPORTED' ''
}
if ($NoShortcuts) { Register-Uninstaller }

if (-not $NoShortcuts) {
    Note "Adding shortcuts to the desktop and the Start menu."
    try {
        Install-Shortcuts
    } catch {
        # Not worth failing an otherwise finished install over.
        Note "Could not add shortcuts: $($_.Exception.Message)"
        Note "EmberStorm still works at $url"
    }
}

# The waiting happens before anything says "finished". It used to come after
# "Opening it now", which then sat for up to 45 seconds with nothing opening.
$secure = ''
if ($tlsMode -eq 'auto') {
    Note "Finishing up: getting a secure address for phones and other devices (up to a minute)."
    $secure = Get-SecureAddress $port
}

Write-Host ""
Write-Host "  ======================================================================" -ForegroundColor Green
if ($upgrade) {
    Write-Host "   UPDATED." -ForegroundColor Green -NoNewline
    Write-Host " EmberStorm is up to date and running." -ForegroundColor White
} else {
    Write-Host "   FINISHED." -ForegroundColor Green -NoNewline
    Write-Host " EmberStorm is installed and running." -ForegroundColor White
}
Write-Host "  ======================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  To add music, films or books: drag them onto the EmberStorm window, or"
Write-Host "  put them in the 'EmberStorm media' folder on your desktop."
Write-Host ""
if ($secure) {
    # The real certificate is in: this address works with no warning on any
    # device, and a phone can install the app from it.
    Write-Host "  On your phone, TV or another computer on this network:"
    Write-Host ""
    Write-Host "    $secure" -ForegroundColor White
    Write-Host ""
    if ($lan) {
        Write-Host "  If that does not load, your router is refusing the name - use" -ForegroundColor Gray
        Write-Host "  http://${lan}:$port instead. Same account either way." -ForegroundColor Gray
    }
    Write-Host "  Worth saving as a bookmark." -ForegroundColor Gray
    Write-Host ""
} elseif ($lan) {
    Write-Host "  On your phone, TV or another computer on this network:"
    Write-Host ""
    Write-Host "    ${scheme}://${lan}:$port" -ForegroundColor White
    Write-Host ""
    if ($tlsMode -eq 'auto') {
        Write-Host "  EmberStorm is still getting its secure address, and moves there" -ForegroundColor Gray
        Write-Host "  by itself when it has one." -ForegroundColor Gray
    }
    Write-Host "  Same account. Worth saving as a bookmark - and worth giving this" -ForegroundColor Gray
    Write-Host "  PC a fixed address in your router, or that number will change." -ForegroundColor Gray
    Write-Host ""
}
if ($lan) { Show-LanAdvice $lanAccess }
if ($useTailscale) {
    Note "Connecting to your tailnet."
    $tailnet = Get-TailnetURL
    Write-Host ""
    if ($tailnet) {
        Write-Host "  From anywhere, on any device signed into your tailnet:"
        Write-Host ""
        Write-Host "    $tailnet" -ForegroundColor White
        Write-Host ""
        Write-Host "  It works away from the house, with nothing forwarded on your" -ForegroundColor Gray
        Write-Host "  router." -ForegroundColor Gray
    } else {
        Write-Host "  Tailscale is starting but has not reported an address yet." -ForegroundColor Yellow
        Write-Host "  Check the Tailscale admin console: this PC should appear there as" -ForegroundColor Gray
        Write-Host "  'soundstorm' within a minute or two." -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Every device that should reach it needs the Tailscale app and the" -ForegroundColor Gray
    Write-Host "  same account. There is no way around that part." -ForegroundColor Gray
    Write-Host ""
}

if ($tlsMode -eq 'self-signed') {
    # Said plainly and up front, because the alternative is somebody deciding
    # their own install is broken or unsafe. Nobody but this PC can vouch for a
    # certificate covering an address like 192.168.0.50, so the warning is
    # unavoidable without a real domain name - but it is fixable per device,
    # and that fix is the useful half of this message.
    Write-Host "  The first visit shows a certificate warning on every device." -ForegroundColor Yellow
    Write-Host "  That is expected: the certificate was made by this PC, and no" -ForegroundColor Gray
    Write-Host "  outside authority can vouch for a home network address." -ForegroundColor Gray
    Write-Host "  Choose Advanced, then continue." -ForegroundColor Gray
    Write-Host ""
    $caHost = if ($lan) { $lan } else { 'localhost' }
    Write-Host "  To stop it asking, open this on each device and install the"
    Write-Host "  certificate it downloads:"
    Write-Host ""
    Write-Host "    https://${caHost}:$port/ca.crt" -ForegroundColor White
    Write-Host ""
    Write-Host "  To go back to plain http, run the setup again with -NoHttps." -ForegroundColor Gray
    Write-Host ""
} elseif ($tlsMode -eq 'off') {
    Write-Host "  Run the setup again with -Https to encrypt the connection." -ForegroundColor Gray
    Write-Host ""
}
if (-not $NoShortcuts) {
    Write-Host "  Next time, click the EmberStorm icon on your desktop." -ForegroundColor Gray
    if (-not $NoAutoStart) {
        Write-Host "  It also starts by itself when you sign in to this PC." -ForegroundColor Gray
    }
}
Write-Host ""

# The one thing to act on goes last, so it is what is on screen when the
# window stops scrolling - and it carries the setup code in full. The code
# used to travel only inside the address the browser was opened at, so
# somebody whose page lost it (or who closed the tab, or opened the desktop
# icon instead) was asked for a code nothing had ever shown them.
$hasAccount = Get-HasAccount $url
# The address for a phone, in the box too: in the window it is the only place
# it would otherwise be, under "Show details".
$phoneLines = @()
$phoneAddress = if ($secure) { $secure } elseif ($lan) { "${scheme}://${lan}:$port" } else { '' }
if ($phoneAddress -and $lanAccess -in @('public', 'refused', 'failed')) {
    $phoneLines = @('', 'Phones and other devices cannot reach it yet: this network is not set as your home network.',
        'On your home network: in Windows Settings, open Network & internet, your network, and set "Network profile type" to Private. Then open EmberStorm from its desktop icon.')
} elseif ($phoneAddress) {
    $phoneLines = @('', 'On your phone, TV or another computer on the same Wi-Fi:', "*  $phoneAddress")
}
$phoneLines += @('', 'To add your music, films and books: drop them in the "EmberStorm media" folder on your desktop, or use Add media in EmberStorm''s Settings.')
if ($useTailscale -and $tailnet) {
    $phoneLines += @('', 'Away from home, on a device signed in to Tailscale:', "*  $tailnet")
}
# A desktop stays off after a power cut unless its BIOS says otherwise -
# something only the person can change, so it is said here.
$isLaptop = $false
try { $isLaptop = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
if (-not $upgrade -and -not $isLaptop) {
    $phoneLines += @('', 'To have this PC switch itself back on after a power cut, turn on',
        '"Restore on AC power loss" (or "Power on after power failure") in its BIOS setup.')
}
$openUrl = $url
if ($hasAccount -ne $true -and $setupCode) {
    Callout 'NEXT: create your account' (@(
        'Your web browser is opening EmberStorm now. On the first screen, choose',
        'a username and password - that is your account for EmberStorm.',
        '',
        'If the page asks for a SETUP CODE, type this one:',
        '',
        "*        $(Format-SetupCode $setupCode)",
        '',
        'Capitals and dashes do not matter.',
        '',
        'Browser did not open? Go to:',
        "*  $url"
    ) + $phoneLines) 'Yellow'
    # With the code in the address too, so the page usually fills it in by
    # itself; it takes it out of the address once it has it.
    if (-not $NoBrowser) { Start-Process "$url/?setup=$setupCode" }
    $openUrl = "$url/?setup=$setupCode"
} else {
    Callout 'NEXT: open EmberStorm' (@(
        'Your web browser is opening EmberStorm now. Sign in as usual.',
        '',
        'Browser did not open? Go to:',
        "*  $url"
    ) + $phoneLines) 'Green'
    if (-not $NoBrowser) { Start-Process $url }
    $openUrl = $url
}

# After a move, the old files are still where they were - moving them for
# somebody is the operation this script never does, because tens of gigabytes
# shifted by a script is exactly what should not fail halfway. What it can do is
# make the move a drag: open both folders, and say which way to drag, in a
# window rather than a console line that scrolls away.
if ($movedFrom) {
    Start-Process explorer.exe -ArgumentList "`"$movedFrom`""
    Start-Process explorer.exe -ArgumentList "`"$libraryPath`""
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
        $owner = New-TopmostOwner
        try {
            [void][System.Windows.Forms.MessageBox]::Show($owner,
                "EmberStorm now keeps your library in:`r`n    $libraryPath`r`n`r`nYour existing files are still in:`r`n    $movedFrom`r`n`r`nBoth folders are open. To bring your files across, select everything inside the old folder (Ctrl+A) and drag it into the new one. If Windows says the folders already exist, click Yes - it adds your files to them. EmberStorm picks them up as they arrive.",
                'EmberStorm - move your files across',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
        } finally {
            $owner.Dispose()
        }
    } catch {
        # The console already said where both folders are.
    }
}

# The window stays up with the result until it is closed: the setup code and
# the address are in it, and closing it is the person's decision, not ours.
if ($upgrade) {
    Complete-Gui 'EmberStorm is up to date' 'It is running. Your library, accounts and settings are as they were.' $openUrl
} else {
    Complete-Gui 'EmberStorm is ready' 'It is installed and running. It starts by itself when you sign in to this PC - after a restart or a power cut, sign in and it comes back.' $openUrl
}
