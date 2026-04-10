module equivalence.path;

import std.file;
import std.path;
import std.algorithm;
import std.container;
import std.array;
import sdlang;

/**
 * Find a migration path between two versions
 */
string[] findMigrationPath(string rulesDir, string fromVer, string toVer) {
    struct Edge {
        string to;
        string file;
    }
    Edge[][string] graph;

    if (!exists(rulesDir)) return [];

    foreach (DirEntry entry; dirEntries(rulesDir, SpanMode.depth)) {
        if (entry.isFile && entry.name.endsWith(".sdl")) {
            auto base = baseName(entry.name, ".sdl");
            auto parts = base.split("-");
            if (parts.length == 2) {
                graph[parts[0]] ~= Edge(parts[1], entry.name.idup);
                
                // Peek for aliases
                try {
                    Tag root = parseFile(entry.name);
                    foreach (tag; root.tags) {
                        if (tag.name == "ruleset" || tag.name == "rule") {
                            foreach (sub; tag.tags) {
                                if (sub.name == "aliases") {
                                    foreach (val; sub.values) {
                                        string aliasVer = val.get!string;
                                        graph[aliasVer] ~= Edge(parts[1], entry.name.idup);
                                        graph[parts[0]] ~= Edge(aliasVer, entry.name.idup);
                                    }
                                }
                            }
                        }
                    }
                } catch (Exception e) {}
            }
        }
    }

    // BFS to find shortest path
    string[][string] parent;
    string[][string] parentFile;
    DList!string queue;
    queue.insertBack(fromVer);
    bool[string] visited;
    visited[fromVer] = true;

    while (!queue.empty) {
        auto current = queue.front;
        queue.removeFront();

        if (current == toVer) {
            // Reconstruct path
            string[] path;
            auto curr = toVer;
            while (curr != fromVer) {
                path ~= parentFile[curr][0];
                curr = parent[curr][0];
            }
            reverse(path);
            return path;
        }

        if (current in graph) {
            foreach (edge; graph[current]) {
                if (edge.to !in visited) {
                    visited[edge.to] = true;
                    parent[edge.to] ~= current;
                    parentFile[edge.to] ~= edge.file;
                    queue.insertBack(edge.to);
                }
            }
        }
    }

    return [];
}

/**
 * Resolve a filesystem intent for a specific context
 */
string[] resolveIntent(string rulesDir, string toContext, string intent) {
    string[] contextPath = toContext.split("/");
    string[] bestFiles;
    string globalIntentPath = buildPath(rulesDir, intent ~ ".sdl");
    string defaultGlobalPath = buildPath(rulesDir, "default", intent ~ ".sdl");
    
    string currentDir = rulesDir;
    foreach (part; contextPath) {
        currentDir = buildPath(currentDir, part);
        string specific = buildPath(currentDir, intent ~ ".sdl");
        string def = buildPath(currentDir, "default", intent ~ ".sdl");
        if (exists(specific)) bestFiles = [specific.idup];
        else if (exists(def)) bestFiles = [def.idup];
    }
    
    if (bestFiles.length == 0) {
        if (exists(globalIntentPath)) return [globalIntentPath.idup];
        if (exists(defaultGlobalPath)) return [defaultGlobalPath.idup];
    }
    return bestFiles;
}
