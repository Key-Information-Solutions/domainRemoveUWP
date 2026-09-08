// KIS Bloatware Cleaner - thin exe host.
// Fetches the live removeUWP.ps1 from KIS SharePoint (so script updates need
// no rebuild -- just edit the synced file), falling back to the copy embedded
// at build time if the download fails or looks wrong. Runs it with a
// process-scoped ExecutionPolicy bypass, passing switches through.
// Elevation comes from the UAC manifest (app.manifest), so double-clicking
// prompts UAC immediately -- local, domain, and Entra admin creds all work.
//
// Pass -Embedded to skip the download and force the baked-in copy (e.g. if a
// bad edit ever lands on SharePoint).
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.Versioning;

[assembly: AssemblyTitle("KIS Bloatware Cleaner")]
[assembly: AssemblyProduct("removeUWP")]
[assembly: AssemblyCompany("Key Information Solutions Inc")]
[assembly: AssemblyVersion("2.1.0.0")]
[assembly: AssemblyFileVersion("2.1.0.0")]
[assembly: TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]

class RemoveUwpHost
{
    // Read-only "Anyone with the link" share of removeUWP.ps1 in
    // KIS Share > Documents > Public > Tools > Bloatware cleaner > source code.
    // If the share link is ever regenerated, update this and rebuild.
    const string ScriptUrl =
        "https://kis.sharepoint.com/:u:/g/IQBgferbFbQfQb3sTVJtopstAS4r_CxJq4lWJHF8Suib7Hs?download=1";

    // Must appear in the script header; guards against SharePoint serving an
    // error/login page (or the wrong file) as if it were the script.
    const string SanityMarker = "KIS Bloatware Cleaner";

    static int Main(string[] args)
    {
        string scriptPath = Path.Combine(Path.GetTempPath(),
            "KIS-removeUWP-" + Guid.NewGuid().ToString("N") + ".ps1");
        try
        {
            bool forceEmbedded = false;
            string passThrough = "";
            foreach (string a in args)
            {
                if (string.Equals(a, "-Embedded", StringComparison.OrdinalIgnoreCase)) { forceEmbedded = true; continue; }
                passThrough += " " + QuoteArg(a);
            }

            string source;
            if (forceEmbedded)
            {
                ExtractEmbeddedScript(scriptPath);
                source = "embedded";
                Console.WriteLine("[removeUWP] -Embedded: using the script baked into this exe.");
            }
            else
            {
                Console.WriteLine("[removeUWP] Fetching latest script from KIS SharePoint...");
                string error = TryDownloadScript(ScriptUrl, scriptPath);
                if (error == null)
                {
                    source = "live";
                    Console.WriteLine("[removeUWP] Using live script from SharePoint.");
                }
                else
                {
                    ExtractEmbeddedScript(scriptPath);
                    source = "embedded";
                    Console.WriteLine("[removeUWP] SharePoint fetch failed (" + error + ").");
                    Console.WriteLine("[removeUWP] Using the script baked into this exe instead.");
                }
            }

            string psArgs = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\""
                + " -ScriptSource " + source + passThrough;

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", psArgs);
            psi.UseShellExecute = false;
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("removeUWP launcher error: " + ex.Message);
            Console.WriteLine("Press Enter to exit...");
            Console.ReadLine();
            return 1;
        }
        finally
        {
            try { if (File.Exists(scriptPath)) File.Delete(scriptPath); } catch { }
        }
    }

    static void ExtractEmbeddedScript(string destPath)
    {
        using (Stream res = Assembly.GetExecutingAssembly().GetManifestResourceStream("removeUWP.ps1"))
        {
            if (res == null) throw new InvalidOperationException("Embedded removeUWP.ps1 resource is missing.");
            using (FileStream outFile = File.Create(destPath)) { res.CopyTo(outFile); }
        }
    }

    // Returns null on success, otherwise a short reason for the failure.
    static string TryDownloadScript(string url, string destPath)
    {
        try
        {
            // Some fleet machines still default to TLS 1.0; SharePoint needs 1.2+.
            // 3072 (0xC00) = SecurityProtocolType.Tls12 on .NET 4.8.
            ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.CookieContainer = new CookieContainer(); // share-link redirect chain sets cookies
            req.AllowAutoRedirect = true;
            req.Timeout = 10000;
            req.ReadWriteTimeout = 10000;
            req.UserAgent = "KIS-removeUWP/2.1";
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            using (Stream s = resp.GetResponseStream())
            using (MemoryStream ms = new MemoryStream())
            {
                s.CopyTo(ms);
                byte[] data = ms.ToArray();
                string text = System.Text.Encoding.UTF8.GetString(data);
                if (text.IndexOf(SanityMarker, StringComparison.OrdinalIgnoreCase) < 0)
                    return "content failed sanity check";
                File.WriteAllBytes(destPath, data);
                return null;
            }
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    static string QuoteArg(string a)
    {
        if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return a;
        return "\"" + a.Replace("\"", "\\\"") + "\"";
    }
}
