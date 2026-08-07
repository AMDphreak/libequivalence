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
    bool interactive = true;
    bool mutableInstall = true;
    bool fallback;
    string auditNote;
    string verifyCommand;
}

private string tagStr(Tag t, string name) {
    auto x = t.getTag(name);
    if (x is null || x.values.length == 0) return "";
    return x.values[0].get!string;
}

private bool tagBool(Tag t, string name, bool defaultVal) {
    auto x = t.getTag(name);
    if (x is null || x.values.length == 0) return defaultVal;
    auto s = x.values[0].get!string.toLower;
    if (s == "true" || s == "1" || s == "yes") return true;
    if (s == "false" || s == "0" || s == "no") return false;
    return defaultVal;
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
    Tag toolsTag = root.getTag("tools");
    if (toolsTag is null) {
        auto catalog = root.getTag("cliToolsCatalog");
        if (catalog !is null)
            toolsTag = catalog.getTag("tools");
    }
    if (toolsTag is null)
        return CliInstallMethod.init;

    Tag matchedTool;
    foreach (toolTag; toolsTag.tags) {
        if (toolTag.name == "tool" && tagStr(toolTag, "id") == toolId) {
            matchedTool = toolTag;
            break;
        }
    }
    if (matchedTool is null)
        return CliInstallMethod.init;

    CliInstallMethod[] methods;
    auto installTag = matchedTool.getTag("install");
    if (installTag is null)
        return CliInstallMethod.init;

    foreach (methodTag; installTag.tags) {
        if (methodTag.name != "method") continue;
        CliInstallMethod m;
        m.toolId = toolId;
        m.context = tagStr(methodTag, "context");
        m.command = tagStr(methodTag, "command");
        m.interactive = tagBool(methodTag, "interactive", true);
        m.mutableInstall = tagBool(methodTag, "mutable", true);
        m.fallback = tagBool(methodTag, "fallback", false);
        m.auditNote = tagStr(methodTag, "auditNote");
        m.verifyCommand = tagStr(matchedTool, "verifyCommand");
        methods ~= m;
    }

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

    // Context inheritance: walk up path (linux/ubuntu/default -> linux/debian/default -> ...)
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
            m.command = tagStr(tag, "command");
            m.interactive = tagBool(tag, "interactive", true);
            m.mutableInstall = tagBool(tag, "mutable", true);
            m.fallback = tagBool(tag, "fallback", false);
            m.auditNote = tagStr(tag, "auditNote");
            m.verifyCommand = tagStr(tag, "verify");
        }
    }
    return m;
}
