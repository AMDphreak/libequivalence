module equivalence.cli;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import sdlang;
import equivalence.path : resolveIntent;

/// Resolved install method for a CLI tool on a host context.
struct CliInstallMethod {
    string toolId;
    string context;
    string command;
    string[] argv;
    string format;
    string runtime = "argv"; // argv | bash | pwsh | nu
    string family;
    string packageManager;
    string[] expand;
    bool interactive = true;
    bool mutableInstall = true;
    bool fallback;
    string auditNote;
    string verifyCommand;
}

/// Host bag used to filter methods. Not a context path that includes a shell.
struct HostCaps {
    string family; // windows | linux | darwin | macos | freebsd | …
    string[] pms;
    string[] formats;
    string[] runtimes; // always include "argv"
    string formatFilter; // optional: keep only this format
    bool preferImmutable = true;
}

struct CatalogContext {
    string id;
    string family;
    string packageManager;
    string format;
    bool mutableInstall = true;
    string inherits;
}

private string valueAsString(T)(T v) {
    try
        return v.get!string;
    catch (Exception)
    {
        try
            return to!string(v.get!bool);
        catch (Exception)
        {
            try
                return to!string(v.get!int);
            catch (Exception)
                return "";
        }
    }
}

private string tagStr(Tag t, string name) {
    auto x = t.getTag(name);
    if (x is null || x.values.length == 0) return "";
    return valueAsString(x.values[0]);
}

private string[] tagStrings(Tag t, string name) {
    auto x = t.getTag(name);
    if (x is null) return [];
    string[] r;
    foreach (v; x.values) {
        auto s = valueAsString(v);
        if (s.length)
            r ~= s;
    }
    return r;
}

private bool tagBool(Tag t, string name, bool defaultVal) {
    auto x = t.getTag(name);
    if (x is null || x.values.length == 0) return defaultVal;
    try
        return x.values[0].get!bool;
    catch (Exception)
    {
        auto s = valueAsString(x.values[0]).toLower;
        if (s == "true" || s == "1" || s == "yes") return true;
        if (s == "false" || s == "0" || s == "no") return false;
        return defaultVal;
    }
}

/// Infer format from a context id or package manager when the catalog omits `format`.
string inferFormat(string context, string packageManager = "") {
    auto pm = packageManager.length ? packageManager : "";
    if (pm.length == 0) {
        auto parts = context.split("/");
        if (parts.length >= 2)
            pm = parts[1];
        else if (parts.length == 1)
            pm = parts[0];
    }
    switch (pm) {
    case "apt":
    case "debian":
        return "deb";
    case "dnf":
    case "yum":
    case "fedora":
        return "rpm";
    case "homebrew":
        return "brew";
    case "curl-script":
        return "script";
    case "npm-global":
        return "npm";
    case "pnpm-dlx":
        return "pnpm";
    default:
        if (pm.length)
            return pm;
        if (context.startsWith("default/curl"))
            return "script";
        return "";
    }
}

string normalizeFamily(string family) {
    auto f = family.toLower;
    if (f == "mac" || f == "macos" || f == "osx")
        return "darwin";
    return f;
}

private Tag findToolsTag(Tag root) {
    auto toolsTag = root.getTag("tools");
    if (toolsTag is null) {
        auto catalog = root.getTag("cliToolsCatalog");
        if (catalog !is null)
            toolsTag = catalog.getTag("tools");
    }
    return toolsTag;
}

private Tag findCatalogRoot(Tag root) {
    auto catalog = root.getTag("cliToolsCatalog");
    return catalog is null ? root : catalog;
}

CatalogContext[] loadCatalogContexts(Tag root) {
    CatalogContext[] outArr;
    auto cat = findCatalogRoot(root);
    auto wrap = cat.getTag("contexts");
    if (wrap is null)
        return outArr;
    foreach (ctxTag; wrap.tags) {
        if (ctxTag.name != "context") continue;
        CatalogContext c;
        c.id = tagStr(ctxTag, "id");
        c.family = tagStr(ctxTag, "family");
        c.packageManager = tagStr(ctxTag, "packageManager");
        c.format = tagStr(ctxTag, "format");
        if (c.format.length == 0)
            c.format = inferFormat(c.id, c.packageManager);
        c.mutableInstall = tagBool(ctxTag, "mutable", true);
        c.inherits = tagStr(ctxTag, "inherits");
        outArr ~= c;
    }
    return outArr;
}

private CatalogContext contextById(CatalogContext[] ctxs, string id) {
    foreach (c; ctxs)
        if (c.id == id)
            return c;
    return CatalogContext.init;
}

private void fillMethodFromTags(ref CliInstallMethod m, Tag methodTag, Tag toolTag, CatalogContext[] ctxs) {
    m.context = tagStr(methodTag, "context");
    auto cmds = tagStrings(methodTag, "command");
    if (cmds.length > 1) {
        m.argv = cmds;
        m.command = cmds.join(" ");
    } else if (cmds.length == 1) {
        m.command = cmds[0];
    }
    m.interactive = tagBool(methodTag, "interactive", true);
    m.fallback = tagBool(methodTag, "fallback", false);
    m.auditNote = tagStr(methodTag, "auditNote");
    m.verifyCommand = tagStr(toolTag, "verifyCommand");
    m.runtime = tagStr(methodTag, "runtime");
    if (m.runtime.length == 0)
        m.runtime = m.argv.length ? "argv" : "argv";
    m.expand = tagStrings(methodTag, "expand");
    auto ctx = contextById(ctxs, m.context);
    m.family = ctx.family;
    m.packageManager = ctx.packageManager;
    m.format = tagStr(methodTag, "format");
    if (m.format.length == 0)
        m.format = ctx.format.length ? ctx.format : inferFormat(m.context, ctx.packageManager);
    if (methodTag.getTag("mutable") is null && ctx.id.length)
        m.mutableInstall = ctx.mutableInstall;
    else
        m.mutableInstall = tagBool(methodTag, "mutable", true);
}

private CliInstallMethod[] loadToolMethods(Tag root, string toolId) {
    auto toolsTag = findToolsTag(root);
    if (toolsTag is null)
        return [];
    auto ctxs = loadCatalogContexts(root);
    Tag matchedTool;
    foreach (toolTag; toolsTag.tags) {
        if (toolTag.name == "tool" && tagStr(toolTag, "id") == toolId) {
            matchedTool = toolTag;
            break;
        }
    }
    if (matchedTool is null)
        return [];
    auto installTag = matchedTool.getTag("install");
    if (installTag is null)
        return [];
    CliInstallMethod[] methods;
    foreach (methodTag; installTag.tags) {
        if (methodTag.name != "method") continue;
        CliInstallMethod m;
        m.toolId = toolId;
        fillMethodFromTags(m, methodTag, matchedTool, ctxs);
        methods ~= m;
    }
    return methods;
}

private CliInstallMethod pickOne(CliInstallMethod[] methods, string context, bool preferImmutable) {
    if (methods.length == 0)
        return CliInstallMethod.init;

    CliInstallMethod[] exact = methods.filter!(m => m.context == context).array;
    if (exact.length > 0) {
        if (preferImmutable) {
            auto imm = exact.filter!(m => !m.mutableInstall).array;
            if (imm.length > 0) return imm[0];
        }
        return exact[0];
    }

    string[] parts = context.split("/");
    while (parts.length > 1) {
        parts = parts[0 .. $ - 1];
        string parentCtx = parts.join("/");
        auto inherited = methods.filter!(m => m.context == parentCtx).array;
        if (inherited.length > 0) {
            if (preferImmutable) {
                auto imm = inherited.filter!(m => !m.mutableInstall).array;
                if (imm.length > 0) return imm[0];
            }
            return inherited[0];
        }
    }

    auto fallbacks = methods.filter!(m => m.fallback).array;
    if (fallbacks.length > 0)
        return fallbacks[0];

    return CliInstallMethod.init;
}

/**
 * Load catalog/tools.sdl and resolve install method for toolId + context.
 * Accepts either a bare `tools { ... }` root or `cliToolsCatalog { tools { ... } }`.
 * Falls back to default/curl-script or npm-global methods marked fallback.
 */
CliInstallMethod resolveCliInstall(string catalogPath, string context, string toolId, bool preferImmutable = true) {
    if (!exists(catalogPath))
        return CliInstallMethod.init;
    Tag root = parseFile(catalogPath);
    return pickOne(loadToolMethods(root, toolId), context, preferImmutable);
}

bool familyMatches(string hostFamily, string methodFamily, string context) {
    auto hf = normalizeFamily(hostFamily);
    auto mf = normalizeFamily(methodFamily);
    if (mf == "cross" || mf.length == 0) {
        if (context.startsWith("default/"))
            return true;
        if (mf == "cross")
            return true;
    }
    if (hf.length && mf.length && hf == mf)
        return true;
    auto ctxFam = context.split("/")[0];
    return normalizeFamily(ctxFam) == hf;
}

private bool methodFitsHost(CliInstallMethod m, HostCaps host) {
    if (host.family.length && !familyMatches(host.family, m.family, m.context))
        return false;
    if (host.formatFilter.length && m.format != host.formatFilter)
        return false;
    if (host.formats.length && m.format.length && !host.formats.canFind(m.format) && !m.fallback)
        return false;
    if (host.pms.length && m.packageManager.length
            && !host.pms.canFind(m.packageManager) && !m.fallback
            && m.family != "cross" && !m.context.startsWith("default/"))
        return false;
    auto rt = m.runtime.length ? m.runtime : "argv";
    if (rt != "argv" && host.runtimes.length && !host.runtimes.canFind(rt))
        return false;
    return true;
}

/// Every method this host can run. Does not pick one. Shell is not a filter axis.
CliInstallMethod[] listCliInstalls(string catalogPath, string toolId, HostCaps host) {
    if (!exists(catalogPath))
        return [];
    Tag root = parseFile(catalogPath);
    auto methods = loadToolMethods(root, toolId);
    CliInstallMethod[] fitted;
    foreach (m; methods) {
        if (methodFitsHost(m, host))
            fitted ~= m;
    }
    if (host.preferImmutable) {
        auto imm = fitted.filter!(m => !m.mutableInstall).array;
        auto mut = fitted.filter!(m => m.mutableInstall).array;
        return imm ~ mut;
    }
    return fitted;
}

/**
 * Per-context rule files under rules/<context>/install/<toolId>.sdl
 * (equivalence-rules-cli layout for equivalence-engine --domain cli).
 */
CliInstallMethod resolveCliInstallFromRulesDir(string rulesDir, string context, string toolId) {
    string[] files = resolveIntent(buildPath(rulesDir, "rules"), context, buildPath("install", toolId));
    if (files.length == 0)
        files = resolveIntent(buildPath(rulesDir, "rules"), context, toolId);

    if (files.length == 0)
        return CliInstallMethod.init;

    Tag root = parseFile(files[0]);
    CliInstallMethod m;
    m.toolId = toolId;
    m.context = context;
    foreach (tag; root.tags) {
        if (tag.name == "tool") {
            auto cmds = tagStrings(tag, "command");
            if (cmds.length > 1) {
                m.argv = cmds;
                m.command = cmds.join(" ");
            } else if (cmds.length == 1) {
                m.command = cmds[0];
            }
            m.interactive = tagBool(tag, "interactive", true);
            m.mutableInstall = tagBool(tag, "mutable", true);
            m.fallback = tagBool(tag, "fallback", false);
            m.auditNote = tagStr(tag, "auditNote");
            m.verifyCommand = tagStr(tag, "verify");
            m.runtime = tagStr(tag, "runtime");
            if (m.runtime.length == 0)
                m.runtime = "argv";
            m.format = tagStr(tag, "format");
            if (m.format.length == 0)
                m.format = inferFormat(context);
        }
    }
    return m;
}

unittest {
    auto sdl = q"SDL
cliToolsCatalog {
    contexts {
        context {
            id "windows/winget"
            family "windows"
            packageManager "winget"
            format "winget"
            mutable true
        }
        context {
            id "linux/nix/default"
            family "linux"
            packageManager "nix"
            format "nix"
            mutable false
        }
        context {
            id "default/curl-script"
            family "cross"
            packageManager "script"
            format "script"
            mutable true
        }
    }
    tools {
        tool {
            id "gh"
            verifyCommand "gh --version"
            install {
                method {
                    context "windows/winget"
                    command "winget" "install" "--id" "GitHub.cli"
                }
                method {
                    context "linux/nix/default"
                    command "nix profile install nixpkgs#gh"
                    mutable false
                }
                method {
                    context "default/curl-script"
                    command "curl -fsSL https://cli.github.com/install.sh | bash"
                    fallback true
                    runtime "bash"
                }
            }
        }
    }
}
SDL";
    import std.file : tempDir, write, remove;
    auto p = buildPath(tempDir(), "libequivalence-cli-test.sdl");
    write(p, sdl);
    scope (exit)
        if (exists(p)) remove(p);

    auto win = resolveCliInstall(p, "windows/winget", "gh");
    assert(win.command.length);
    assert(win.format == "winget");
    assert(win.argv.length >= 3);

    auto nix = resolveCliInstall(p, "linux/nix/default", "gh");
    assert(nix.format == "nix");
    assert(!nix.mutableInstall);

    HostCaps linuxNix;
    linuxNix.family = "linux";
    linuxNix.pms = ["nix", "apt"];
    linuxNix.formats = ["nix", "deb", "script"];
    linuxNix.runtimes = ["argv", "bash"];
    auto listed = listCliInstalls(p, "gh", linuxNix);
    assert(listed.length >= 1);
    assert(listed[0].format == "nix" || listed.canFind!(m => m.format == "nix"));

    HostCaps winCaps;
    winCaps.family = "windows";
    winCaps.pms = ["winget"];
    winCaps.formats = ["winget", "msi"];
    winCaps.runtimes = ["argv"];
    winCaps.formatFilter = "winget";
    auto onlyWinget = listCliInstalls(p, "gh", winCaps);
    assert(onlyWinget.length == 1);
    assert(onlyWinget[0].format == "winget");
}
