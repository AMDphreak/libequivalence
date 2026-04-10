module equivalence.engine;

import std.stdio;
import std.file;
import std.path;
import std.regex;
import std.array;
import std.algorithm;
import std.uni;
import sdlang;

/**
 * A transformation rule
 */
struct Rule {
    string type;
    string target;
    string replacement;
    string message;
}

/**
 * A finding from the engine
 */
struct Finding {
    string type;
    string message;
}

/**
 * The core rule-based transformation engine
 */
class RuleEngine {
    Rule[] rules;
    Finding[][string] findings;
    string currentRepo;

    /**
     * Load rules from an SDL file
     */
    void loadRules(string sdlPath) {
        if (!exists(sdlPath)) {
            throw new Exception("Rules file not found: " ~ sdlPath);
        }

        try {
            Tag root = parseFile(sdlPath);
            foreach (tag; root.tags) {
                if (tag.name == "repo") {
                    currentRepo = tag.values[0].get!string;
                }
                if (tag.name == "ruleset" || tag.name == "rule") {
                    foreach (ruleTag; tag.tags) {
                        Rule r;
                        r.type = ruleTag.name;
                        if (r.type == "replace" || r.type == "regex") {
                            r.target = ruleTag.values[0].get!string;
                            r.replacement = ruleTag.values[1].get!string;
                        } else if (r.type == "warn" || r.type == "note") {
                            r.target = ruleTag.values[0].get!string;
                            r.message = ruleTag.values[1].get!string;
                        } else if (r.type == "aliases") {
                            continue;
                        }
                        rules ~= r;
                    }
                }
            }
        } catch (Exception e) {
            throw new Exception("Error parsing SDL rules: " ~ e.msg);
        }
    }

    /**
     * Parse rules from an SDL string (useful for embedded/remote rules)
     */
    void parseRules(string content) {
        try {
            Tag root = parseSource(content);
            foreach (tag; root.tags) {
                if (tag.name == "repo") {
                    currentRepo = tag.values[0].get!string;
                }
                if (tag.name == "ruleset" || tag.name == "rule") {
                    foreach (ruleTag; tag.tags) {
                        Rule r;
                        r.type = ruleTag.name;
                        if (r.type == "replace" || r.type == "regex") {
                            r.target = ruleTag.values[0].get!string;
                            r.replacement = ruleTag.values[1].get!string;
                        } else if (r.type == "warn" || r.type == "note") {
                            r.target = ruleTag.values[0].get!string;
                            r.message = ruleTag.values[1].get!string;
                        } else if (r.type == "aliases") {
                            continue;
                        }
                        rules ~= r;
                    }
                }
            }
        } catch (Exception e) {
            throw new Exception("Error parsing SDL rules: " ~ e.msg);
        }
    }

    /**
     * Apply rules to a string
     */
    string applyRules(string content, string fileName = "default") {
        foreach (rule; rules) {
            if (rule.type == "replace") {
                content = content.replace(rule.target, rule.replacement);
            } else if (rule.type == "regex") {
                auto re = regex(rule.target);
                content = replaceAll(content, re, rule.replacement);
            } else if (rule.type == "warn" || rule.type == "note") {
                if (content.canFind(rule.target)) {
                    findings[fileName] ~= Finding(rule.type.toUpper(), rule.message);
                }
            }
        }
        return content;
    }

    /**
     * Clear all current findings
     */
    void clearFindings() {
        findings = null;
    }
}
