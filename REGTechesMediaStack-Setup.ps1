<#
    REGTeches Media Stack -- GUI Setup
    Developed by Ronald Goodchild for your pleasure

    Friendly WPF front-end for Install-REGTechesMediaStack.ps1. Launch this
    unelevated; it relaunches the real installer elevated once you click Install.
#>

Add-Type -AssemblyName PresentationFramework

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="REGTeches Media Stack Setup"
        Height="480" Width="520" WindowStartupLocation="CenterScreen"
        Background="#0b0c10" Foreground="#c5c6c7">
  <Grid Margin="15">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,15">
      <TextBlock Text="REGTeches Media Stack" FontSize="24" Foreground="#66fcf1" FontWeight="Bold"/>
      <TextBlock Text="Developed by Ronald Goodchild for your pleasure" FontSize="12" Margin="0,4,0,0"/>
    </StackPanel>

    <StackPanel Grid.Row="1">
      <TextBlock Text="Install location (apps, downloads, config):" Margin="0,0,0,4"/>
      <TextBox Name="InstallPathBox" Text="C:\REGTechesMediaStack" Padding="4" Margin="0,0,0,15"/>

      <TextBlock Text="Media storage (Movies &amp; TV go here):" Margin="0,0,0,4"/>
      <TextBox Name="MediaPathBox" Text="\\192.168.1.50\vol3\media" Padding="4" Margin="0,0,0,4"/>
      <TextBlock Text="A separate drive (e.g. D:\Media) or a mapped/UNC NAS path (e.g. \\192.168.1.50\vol3\media, DS420J). Must already exist and be reachable." FontSize="10" Foreground="#9a9a9a" TextWrapping="Wrap" Margin="0,0,0,15"/>

      <TextBlock Text="Login for all apps:" Margin="0,0,0,4"/>
      <Grid Margin="0,0,0,15">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="10"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBox Name="AdminUserBox" Grid.Column="0" Text="media" Padding="4"/>
        <PasswordBox Name="AdminPassBox" Grid.Column="2" Password="" ToolTip="Leave blank to generate a random password" Padding="4"/>
      </Grid>

      <TextBlock Text="Apps to install:" Margin="0,0,0,4" FontWeight="Bold"/>
      <CheckBox Name="ChkProwlarr" Content="Prowlarr (indexer manager)" IsChecked="True" Margin="0,2"/>
      <CheckBox Name="ChkSonarr"   Content="Sonarr (TV)" IsChecked="True" Margin="0,2"/>
      <CheckBox Name="ChkRadarr"   Content="Radarr (Movies)" IsChecked="True" Margin="0,2"/>
      <CheckBox Name="ChkLidarr"   Content="Lidarr (Music)" IsChecked="True" Margin="0,2"/>
      <CheckBox Name="ChkReadarr"  Content="Readarr (Books)" IsChecked="True" Margin="0,2"/>
      <CheckBox Name="ChkWhisparr" Content="Whisparr (Adult)" IsChecked="False" Margin="0,2"/>
      <CheckBox Name="ChkSabnzbd"  Content="SABnzbd (download client)" IsChecked="True" Margin="0,2"/>
      <CheckBox Name="ChkJellyfin" Content="Jellyfin (media server)" IsChecked="True" Margin="0,2"/>

      <CheckBox Name="ChkFirewall" Content="Allow access from other devices on my LAN" IsChecked="False" Margin="0,15,0,0"/>
    </StackPanel>

    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
      <Button Name="InstallButton" Content="Install" Width="110" Height="30" Margin="0,0,10,0"/>
      <Button Name="CancelButton" Content="Cancel" Width="90" Height="30"/>
    </StackPanel>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$InstallPathBox = $window.FindName("InstallPathBox")
$MediaPathBox = $window.FindName("MediaPathBox")
$AdminUserBox = $window.FindName("AdminUserBox")
$AdminPassBox = $window.FindName("AdminPassBox")
$checks = @{
    Prowlarr = $window.FindName("ChkProwlarr")
    Sonarr   = $window.FindName("ChkSonarr")
    Radarr   = $window.FindName("ChkRadarr")
    Lidarr   = $window.FindName("ChkLidarr")
    Readarr  = $window.FindName("ChkReadarr")
    Whisparr = $window.FindName("ChkWhisparr")
    SABnzbd  = $window.FindName("ChkSabnzbd")
    Jellyfin = $window.FindName("ChkJellyfin")
}
$ChkFirewall = $window.FindName("ChkFirewall")
$InstallButton = $window.FindName("InstallButton")
$CancelButton = $window.FindName("CancelButton")

$InstallButton.Add_Click({
    # Prefer the compiled installer (built via Build-Executables.ps1) if it's
    # sitting next to this script -- native UAC shield/prompt instead of
    # relaunching powershell.exe by hand. Falls back to the raw .ps1 so this
    # GUI still works standalone if the exe was never built.
    $installerExe = Join-Path $PSScriptRoot "Install-REGTechesMediaStack.exe"
    $installerScript = Join-Path $PSScriptRoot "Install-REGTechesMediaStack.ps1"
    $useExe = Test-Path $installerExe
    if (-not $useExe -and -not (Test-Path $installerScript)) {
        [System.Windows.MessageBox]::Show("Neither Install-REGTechesMediaStack.exe nor Install-REGTechesMediaStack.ps1 was found next to this script.", "REGTeches Media Stack", "OK", "Error") | Out-Null
        return
    }

    $mediaPath = $MediaPathBox.Text.Trim()
    if ($mediaPath) {
        $mediaDriveRoot = [System.IO.Path]::GetPathRoot($mediaPath)
        if (-not $mediaDriveRoot -or -not (Test-Path $mediaDriveRoot)) {
            $proceed = [System.Windows.MessageBox]::Show(
                "Media storage path '$mediaPath' isn't reachable right now (drive/share '$mediaDriveRoot' not found) -- if this is a NAS drive you'll map later, map it first, then run this.`n`nContinue anyway?",
                "REGTeches Media Stack", "YesNo", "Warning")
            if ($proceed -ne "Yes") { return }
        }
    }

    $skip = @()
    foreach ($name in $checks.Keys) {
        if (-not $checks[$name].IsChecked) { $skip += $name }
    }

    $installerArgs = @(
        "-InstallRoot", "`"$($InstallPathBox.Text)`"",
        "-AdminUsername", "`"$($AdminUserBox.Text)`""
    )
    if ($AdminPassBox.Password) { $installerArgs += @("-AdminPassword", "`"$($AdminPassBox.Password)`"") }   # blank = generated
    if ($mediaPath) { $installerArgs += @("-MediaRoot", "`"$mediaPath`"") }
    if ($skip.Count -gt 0) {
        $installerArgs += "-SkipApps"
        $installerArgs += ($skip -join ",")
    }
    if ($ChkFirewall.IsChecked) { $installerArgs += "-OpenFirewallPorts" }

    if ($useExe) {
        Start-Process -FilePath $installerExe -ArgumentList ($installerArgs -join " ") -Verb RunAs
    } else {
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$installerScript`"") + $installerArgs
        Start-Process -FilePath "powershell.exe" -ArgumentList ($argList -join " ") -Verb RunAs
    }
    $window.Close()
})

$CancelButton.Add_Click({ $window.Close() })

$window.ShowDialog() | Out-Null
