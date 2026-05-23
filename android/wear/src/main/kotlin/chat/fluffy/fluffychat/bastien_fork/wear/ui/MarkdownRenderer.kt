package chat.fluffy.fluffychat.bastien_fork.wear.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration

/**
 * Parser léger markdown ou HTML Matrix → AnnotatedString Compose.
 *
 * Priorité : si `formattedBody` (HTML Matrix `org.matrix.custom.html`) dispo → parse HTML.
 * Sinon : parse le markdown brut du body.
 *
 * Tags HTML supportés : <b>, <strong>, <i>, <em>, <code>, <s>, <del>, <u>, <a>, <br>,
 *                       <blockquote>, <p>, <pre>, <h1-6>, <li>, <ul>, <ol>
 * Markdown : **bold**, __bold__, *italic*, _italic_, `code`, ~~strike~~, [text](url), > quote
 *
 * Non supporté (V1) : tables, images inline, nested formatting parfait, custom emoji
 */
object MarkdownRenderer {

    private val CODE_BG = Color(0xFF1F1B2E)
    private val LINK_COLOR = Color(0xFF22D3EE)
    private val QUOTE_COLOR = Color(0xFFA78BFA)

    fun render(body: String, formattedBody: String?): AnnotatedString {
        return if (!formattedBody.isNullOrBlank()) {
            parseHtml(formattedBody)
        } else {
            parseMarkdown(body)
        }
    }

    /* -------- HTML parser minimal -------- */

    fun parseHtml(html: String): AnnotatedString {
        // Décode entities HTML basiques
        val decoded = html
            .replace("&nbsp;", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")

        return buildAnnotatedString {
            val styleStack = ArrayDeque<SpanStyle>()
            var i = 0
            while (i < decoded.length) {
                if (decoded[i] == '<') {
                    val end = decoded.indexOf('>', i)
                    if (end == -1) {
                        append(decoded[i])
                        i++
                        continue
                    }
                    val tag = decoded.substring(i + 1, end).trim()
                    when {
                        tag.equals("br", true) || tag.equals("br/", true) || tag.equals("br /", true) -> {
                            append('\n')
                        }
                        tag.equals("p", true) -> {
                            // open <p> : pas de style additionnel
                        }
                        tag.equals("/p", true) -> append("\n\n")
                        tag.equals("b", true) || tag.equals("strong", true) -> {
                            val s = SpanStyle(fontWeight = FontWeight.Bold)
                            styleStack.addLast(s); pushStyle(s)
                        }
                        tag.equals("/b", true) || tag.equals("/strong", true) -> popIfPresent(styleStack)
                        tag.equals("i", true) || tag.equals("em", true) -> {
                            val s = SpanStyle(fontStyle = FontStyle.Italic)
                            styleStack.addLast(s); pushStyle(s)
                        }
                        tag.equals("/i", true) || tag.equals("/em", true) -> popIfPresent(styleStack)
                        tag.equals("s", true) || tag.equals("del", true) || tag.equals("strike", true) -> {
                            val s = SpanStyle(textDecoration = TextDecoration.LineThrough)
                            styleStack.addLast(s); pushStyle(s)
                        }
                        tag.equals("/s", true) || tag.equals("/del", true) || tag.equals("/strike", true) -> popIfPresent(styleStack)
                        tag.equals("u", true) -> {
                            val s = SpanStyle(textDecoration = TextDecoration.Underline)
                            styleStack.addLast(s); pushStyle(s)
                        }
                        tag.equals("/u", true) -> popIfPresent(styleStack)
                        tag.equals("code", true) || tag.equals("pre", true) -> {
                            val s = SpanStyle(
                                fontFamily = FontFamily.Monospace,
                                background = CODE_BG
                            )
                            styleStack.addLast(s); pushStyle(s)
                        }
                        tag.equals("/code", true) || tag.equals("/pre", true) -> popIfPresent(styleStack)
                        tag.equals("blockquote", true) -> {
                            append("│ ")
                            val s = SpanStyle(color = QUOTE_COLOR, fontStyle = FontStyle.Italic)
                            styleStack.addLast(s); pushStyle(s)
                        }
                        tag.equals("/blockquote", true) -> {
                            popIfPresent(styleStack)
                            append('\n')
                        }
                        tag.startsWith("h", true) && tag.length == 2 && tag[1].isDigit() -> {
                            val s = SpanStyle(fontWeight = FontWeight.Bold)
                            styleStack.addLast(s); pushStyle(s)
                        }
                        tag.startsWith("/h", true) && tag.length == 3 && tag[2].isDigit() -> {
                            popIfPresent(styleStack); append('\n')
                        }
                        tag.equals("li", true) -> append("• ")
                        tag.equals("/li", true) -> append('\n')
                        tag.equals("ul", true) || tag.equals("ol", true) ||
                                tag.equals("/ul", true) || tag.equals("/ol", true) -> Unit
                        tag.startsWith("a ", true) || tag == "a" -> {
                            // Extract href si présent
                            val hrefMatch = Regex("""href\s*=\s*['"]([^'"]+)['"]""", RegexOption.IGNORE_CASE).find(tag)
                            val s = SpanStyle(
                                color = LINK_COLOR,
                                textDecoration = TextDecoration.Underline
                            )
                            styleStack.addLast(s); pushStyle(s)
                            hrefMatch?.groupValues?.get(1)?.let {
                                addStringAnnotation(tag = "URL", annotation = it, start = length, end = length)
                            }
                        }
                        tag.equals("/a", true) -> popIfPresent(styleStack)
                        // span, mx-reply, font, etc. → ignore le tag mais garde le contenu
                        else -> Unit
                    }
                    i = end + 1
                } else {
                    append(decoded[i])
                    i++
                }
            }
            // Cleanup styles ouvertes non fermées
            while (styleStack.isNotEmpty()) {
                popIfPresent(styleStack)
            }
        }
    }

    private fun androidx.compose.ui.text.AnnotatedString.Builder.popIfPresent(stack: ArrayDeque<SpanStyle>) {
        if (stack.isNotEmpty()) {
            stack.removeLast()
            pop()
        }
    }

    /* -------- Markdown parser minimal -------- */

    fun parseMarkdown(text: String): AnnotatedString {
        return buildAnnotatedString {
            val lines = text.split('\n')
            for ((idx, line) in lines.withIndex()) {
                val trimmed = line.trimStart()
                when {
                    trimmed.startsWith("> ") -> {
                        append("│ ")
                        withSpan(SpanStyle(color = QUOTE_COLOR, fontStyle = FontStyle.Italic)) {
                            parseInline(trimmed.substring(2))
                        }
                    }
                    trimmed.startsWith("# ") -> {
                        withSpan(SpanStyle(fontWeight = FontWeight.Bold)) {
                            parseInline(trimmed.substring(2))
                        }
                    }
                    trimmed.startsWith("## ") -> {
                        withSpan(SpanStyle(fontWeight = FontWeight.Bold)) {
                            parseInline(trimmed.substring(3))
                        }
                    }
                    trimmed.startsWith("### ") -> {
                        withSpan(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                            parseInline(trimmed.substring(4))
                        }
                    }
                    trimmed.startsWith("- ") || trimmed.startsWith("* ") -> {
                        append("• ")
                        parseInline(trimmed.substring(2))
                    }
                    else -> parseInline(line)
                }
                if (idx < lines.lastIndex) append('\n')
            }
        }
    }

    /**
     * Parse inline markdown : **bold**, *italic*, _italic_, `code`, ~~strike~~, [text](url).
     * Implem itérative greedy left-first.
     */
    private fun androidx.compose.ui.text.AnnotatedString.Builder.parseInline(text: String) {
        var i = 0
        while (i < text.length) {
            val rest = text.substring(i)
            // ** bold **
            val boldStart = "**"
            if (rest.startsWith(boldStart)) {
                val endIdx = rest.indexOf(boldStart, startIndex = 2)
                if (endIdx > 2) {
                    withSpan(SpanStyle(fontWeight = FontWeight.Bold)) {
                        parseInline(rest.substring(2, endIdx))
                    }
                    i += endIdx + 2
                    continue
                }
            }
            // __ bold __ (alternatif)
            if (rest.startsWith("__")) {
                val endIdx = rest.indexOf("__", startIndex = 2)
                if (endIdx > 2) {
                    withSpan(SpanStyle(fontWeight = FontWeight.Bold)) {
                        parseInline(rest.substring(2, endIdx))
                    }
                    i += endIdx + 2
                    continue
                }
            }
            // ~~ strikethrough ~~
            if (rest.startsWith("~~")) {
                val endIdx = rest.indexOf("~~", startIndex = 2)
                if (endIdx > 2) {
                    withSpan(SpanStyle(textDecoration = TextDecoration.LineThrough)) {
                        parseInline(rest.substring(2, endIdx))
                    }
                    i += endIdx + 2
                    continue
                }
            }
            // * italic * (mais pas si c'est ** déjà traité ci-dessus)
            if (rest.startsWith("*") && !rest.startsWith("**")) {
                val endIdx = rest.indexOf("*", startIndex = 1)
                if (endIdx > 1) {
                    withSpan(SpanStyle(fontStyle = FontStyle.Italic)) {
                        parseInline(rest.substring(1, endIdx))
                    }
                    i += endIdx + 1
                    continue
                }
            }
            // _ italic _ (mais pas si __ )
            if (rest.startsWith("_") && !rest.startsWith("__")) {
                val endIdx = rest.indexOf("_", startIndex = 1)
                if (endIdx > 1) {
                    withSpan(SpanStyle(fontStyle = FontStyle.Italic)) {
                        parseInline(rest.substring(1, endIdx))
                    }
                    i += endIdx + 1
                    continue
                }
            }
            // ` inline code `
            if (rest.startsWith("`")) {
                val endIdx = rest.indexOf("`", startIndex = 1)
                if (endIdx > 1) {
                    withSpan(SpanStyle(fontFamily = FontFamily.Monospace, background = CODE_BG)) {
                        append(rest.substring(1, endIdx))
                    }
                    i += endIdx + 1
                    continue
                }
            }
            // [text](url)
            if (rest.startsWith("[")) {
                val closeBracket = rest.indexOf(']')
                if (closeBracket > 0 && closeBracket < rest.length - 1 && rest[closeBracket + 1] == '(') {
                    val closeParen = rest.indexOf(')', closeBracket + 2)
                    if (closeParen > closeBracket) {
                        val linkText = rest.substring(1, closeBracket)
                        val url = rest.substring(closeBracket + 2, closeParen)
                        val startMark = length
                        withSpan(
                            SpanStyle(
                                color = LINK_COLOR,
                                textDecoration = TextDecoration.Underline
                            )
                        ) {
                            append(linkText)
                        }
                        addStringAnnotation(tag = "URL", annotation = url, start = startMark, end = length)
                        i += closeParen + 1
                        continue
                    }
                }
            }
            // sinon caractère normal
            append(text[i])
            i++
        }
    }

    private inline fun androidx.compose.ui.text.AnnotatedString.Builder.withSpan(
        style: SpanStyle,
        block: () -> Unit
    ) {
        pushStyle(style)
        try {
            block()
        } finally {
            pop()
        }
    }
}
