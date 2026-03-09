import Foundation

enum TwitterCSSInjector {

    // MARK: - Bootstrap (injected at document start, before render)

    static func buildBootstrapScript(isDark: Bool) -> String {
        let css = buildCSS(isDark: isDark)
        // Inject <style> immediately + MutationObserver to re-inject if React removes it
        return """
        (function() {
            var styleId = '__omni_twitter_style';

            function injectStyle() {
                if (document.getElementById(styleId)) return;
                var s = document.createElement('style');
                s.id = styleId;
                s.textContent = \(jsStringLiteral(css));
                (document.head || document.documentElement).appendChild(s);
            }

            injectStyle();

            // MutationObserver: re-inject if React removes our <style>
            var obs = new MutationObserver(function() {
                if (!document.getElementById(styleId)) injectStyle();
            });
            if (document.head) {
                obs.observe(document.head, { childList: true });
            } else {
                document.addEventListener('DOMContentLoaded', function() {
                    obs.observe(document.head, { childList: true });
                });
            }
        })();
        """
    }

    // MARK: - Runtime theme update

    static func buildRuntimeUpdateScript(isDark: Bool) -> String {
        let css = buildCSS(isDark: isDark)
        return """
        (function() {
            var s = document.getElementById('__omni_twitter_style');
            if (s) {
                s.textContent = \(jsStringLiteral(css));
            }
        })();
        """
    }

    // MARK: - CSS Assembly

    private static func buildCSS(isDark: Bool) -> String {
        return [
            adRemovalCSS,
            immersiveLayoutCSS,
            typographyCSS(isDark: isDark),
            cardStyleCSS(isDark: isDark),
            themeCSS(isDark: isDark),
            scrollbarCSS(isDark: isDark),
        ].joined(separator: "\n\n")
    }

    // MARK: - Module a) Ad & clutter removal

    private static let adRemovalCSS = """
    /* Promoted tweets */
    [data-testid="tweet"] div[dir="ltr"] span:has(> span > svg[data-testid="icon-verified"]) ~ div:empty,
    article:has([data-testid="placementTracking"]) { display: none !important; }

    /* "Who to follow" / "You might like" sections */
    [data-testid="UserCell"] { display: none !important; }
    aside[role="complementary"] [data-testid="UserCell"] { display: none !important; }

    /* Trending / "What's happening" */
    [data-testid="trend"] { display: none !important; }

    /* Premium / subscribe banners */
    a[href="/i/verified-choose"],
    a[href="/i/premium_sign_up"],
    [data-testid="verified-phone-banner"],
    div[data-testid="inlinePrompt"] { display: none !important; }

    /* Footer links */
    nav[aria-label="Footer"] { display: none !important; }

    /* "Get Verified" / "Subscribe to Premium" sidebar cards */
    aside[role="complementary"] > div > div > div:has(a[href*="premium"]),
    aside[role="complementary"] > div > div > div:has(a[href*="verified"]) { display: none !important; }

    /* "Sign up" / "Log in" bottom bar for logged-out */
    #layers > div:has([data-testid="sheetDialog"]) { display: none !important; }

    /* Grok fab button */
    a[href="/i/grok"],
    [data-testid="GrokDrawer"] { display: none !important; }
    """

    // MARK: - Module b) Immersive layout (hide sidebars)

    private static let immersiveLayoutCSS = """
    /* Hide left sidebar nav */
    header[role="banner"] { display: none !important; }

    /* Hide right sidebar */
    [data-testid="sidebarColumn"] { display: none !important; }

    /* Make main column full width, centered */
    main[role="main"] {
        max-width: 100% !important;
        margin: 0 auto !important;
    }

    [data-testid="primaryColumn"] {
        max-width: 680px !important;
        margin: 0 auto !important;
        border-left: none !important;
        border-right: none !important;
    }

    /* Remove the min-width that causes horizontal scroll */
    body, #react-root, #react-root > div {
        min-width: 0 !important;
    }
    """

    // MARK: - Module c) Typography

    private static func typographyCSS(isDark: Bool) -> String {
        let textColor = isDark ? "#e7e9ea" : "#0f1419"
        let secondaryColor = isDark ? "#71767b" : "#536471"
        return """
        /* Tweet text */
        [data-testid="tweetText"] {
            font-size: 16px !important;
            line-height: 1.6 !important;
            color: \(textColor) !important;
            letter-spacing: 0.01em !important;
        }

        /* Username (display name) */
        [data-testid="User-Name"] a > div > span {
            font-weight: 700 !important;
        }

        /* Handle & timestamp */
        [data-testid="User-Name"] div[dir="ltr"]:not(:first-child) {
            color: \(secondaryColor) !important;
        }
        """
    }

    // MARK: - Module d) Card style

    private static func cardStyleCSS(isDark: Bool) -> String {
        let cardBg = isDark ? "#16181c" : "#ffffff"
        let borderColor = isDark ? "#2f3336" : "#eff3f4"
        let hoverBg = isDark ? "#1d1f23" : "#f7f9f9"
        let shadowColor = isDark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.04)"
        return """
        /* Card style for each tweet */
        [data-testid="cellInnerDiv"]:has(article[data-testid="tweet"]) {
            background: \(cardBg) !important;
            border: 1px solid \(borderColor) !important;
            border-radius: 16px !important;
            margin: 8px 12px !important;
            padding: 4px 0 !important;
            transition: box-shadow 0.2s ease, background 0.2s ease !important;
        }

        [data-testid="cellInnerDiv"]:has(article[data-testid="tweet"]):hover {
            background: \(hoverBg) !important;
            box-shadow: 0 2px 12px \(shadowColor) !important;
        }

        /* Remove default bottom border */
        [data-testid="cellInnerDiv"] {
            border-bottom: none !important;
        }

        /* Image rounding */
        [data-testid="tweetPhoto"] img {
            border-radius: 12px !important;
        }

        /* Avatar rounding */
        [data-testid="Tweet-User-Avatar"] img {
            border-radius: 50% !important;
        }
        """
    }

    // MARK: - Module e) Theme override

    private static func themeCSS(isDark: Bool) -> String {
        let bg = isDark ? "#000000" : "#f5f5f5"
        let headerBg = isDark ? "#000000" : "#ffffff"
        return """
        /* Page background */
        body {
            background-color: \(bg) !important;
        }

        /* Top bar */
        [data-testid="TopNavBar"],
        div[data-testid="primaryColumn"] > div > div:first-child {
            background-color: \(headerBg) !important;
        }
        """
    }

    // MARK: - Scrollbar

    private static func scrollbarCSS(isDark: Bool) -> String {
        let thumbColor = isDark ? "#3a3a3a" : "#c0c0c0"
        let trackColor = isDark ? "#000000" : "#f5f5f5"
        return """
        /* Custom scrollbar */
        ::-webkit-scrollbar { width: 8px !important; }
        ::-webkit-scrollbar-track { background: \(trackColor) !important; }
        ::-webkit-scrollbar-thumb {
            background: \(thumbColor) !important;
            border-radius: 4px !important;
        }
        ::-webkit-scrollbar-thumb:hover {
            background: \(isDark ? "#555" : "#999") !important;
        }
        """
    }

    // MARK: - Helper

    private static func jsStringLiteral(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return "`\(escaped)`"
    }
}
