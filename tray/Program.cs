// REGTeches Media Stack -- Tray App
// Developed by Ronald Goodchild for your pleasure

using System;
using System.Diagnostics;
using System.ServiceProcess;
using System.Windows.Forms;

namespace REGTechesMediaStackTray
{
    internal static class Program
    {
        private static readonly (string Label, string Url, string ServiceName)[] Apps = new[]
        {
            ("Dashboard", "http://localhost:8090", "REGTMS-Dashboard"),
            ("Prowlarr",  "http://localhost:9696", "REGTMS-Prowlarr"),
            ("Sonarr",    "http://localhost:8989", "REGTMS-Sonarr"),
            ("Radarr",    "http://localhost:7878", "REGTMS-Radarr"),
            ("Lidarr",    "http://localhost:8686", "REGTMS-Lidarr"),
            ("Readarr",   "http://localhost:8787", "REGTMS-Readarr"),
            ("Whisparr",  "http://localhost:6969", "REGTMS-Whisparr"),
            // SABnzbd, qBittorrent, and Jellyfin all run as logon Scheduled
            // Tasks, not services (Session 0, where Windows services run,
            // breaks all three -- see install log) -- the "TASK:" prefix
            // tells RestartService to use schtasks instead of SCM.
            ("SABnzbd",   "http://localhost:8080", "TASK:REGTeches Media Stack - SABnzbd"),
            ("qBittorrent", "http://localhost:8181", "TASK:REGTeches Media Stack - qBittorrent"),
            ("Jellyfin",  "http://localhost:8096", "TASK:REGTeches Media Stack - Jellyfin"),
        };

        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            var tray = new NotifyIcon
            {
                Icon = System.Drawing.SystemIcons.Application,
                Visible = true,
                Text = "REGTeches Media Stack"
            };

            tray.ContextMenuStrip = BuildMenu(tray);
            tray.DoubleClick += (s, e) => OpenUrl("http://localhost:8090");

            Application.ApplicationExit += (s, e) => tray.Visible = false;
            Application.Run();
        }

        private static ContextMenuStrip BuildMenu(NotifyIcon tray)
        {
            var menu = new ContextMenuStrip();

            foreach (var app in Apps)
            {
                var item = new ToolStripMenuItem(app.Label);
                item.Click += (s, e) => OpenUrl(app.Url);
                menu.Items.Add(item);
            }

            menu.Items.Add(new ToolStripSeparator());

            var restartAll = new ToolStripMenuItem("Restart all services");
            restartAll.Click += (s, e) =>
            {
                foreach (var app in Apps) RestartService(app.ServiceName);
                MessageBox.Show("Restart requested for all REGTeches Media Stack services.",
                    "REGTeches Media Stack", MessageBoxButtons.OK, MessageBoxIcon.Information);
            };
            menu.Items.Add(restartAll);

            var viewLogs = new ToolStripMenuItem("View logs folder");
            viewLogs.Click += (s, e) => Process.Start("explorer.exe", @"C:\REGTechesMediaStack\logs");
            menu.Items.Add(viewLogs);

            menu.Items.Add(new ToolStripSeparator());

            var exit = new ToolStripMenuItem("Exit");
            exit.Click += (s, e) => Application.Exit();
            menu.Items.Add(exit);

            return menu;
        }

        private static void OpenUrl(string url)
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }

        private static void RestartService(string serviceName)
        {
            if (serviceName.StartsWith("TASK:", StringComparison.Ordinal))
            {
                var taskName = serviceName.Substring("TASK:".Length);
                try
                {
                    Process.Start(new ProcessStartInfo("schtasks.exe", $"/End /TN \"{taskName}\"") { CreateNoWindow = true, UseShellExecute = false })?.WaitForExit(5000);
                    Process.Start(new ProcessStartInfo("schtasks.exe", $"/Run /TN \"{taskName}\"") { CreateNoWindow = true, UseShellExecute = false });
                }
                catch
                {
                    // Task may not be registered (e.g. qBittorrent skipped at install time) -- ignore.
                }
                return;
            }

            try
            {
                using var sc = new ServiceController(serviceName);
                if (sc.Status == ServiceControllerStatus.Running)
                {
                    sc.Stop();
                    sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20));
                }
                sc.Start();
            }
            catch
            {
                // Service may not be installed (e.g. Whisparr skipped at install time) -- ignore.
            }
        }
    }
}
