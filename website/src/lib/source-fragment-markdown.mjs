// This deliberately small parser accepts only Pace's authored prose fragments.
// It never receives emitted HTML, executes expressions, or includes site chrome.
export function sourceFragmentMarkdown(source, origin) {
  const entities = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
  const decode = (value) => value.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (all, entity) => {
    if (entity.startsWith("#x")) return String.fromCodePoint(parseInt(entity.slice(2), 16));
    if (entity.startsWith("#")) return String.fromCodePoint(Number(entity.slice(1)));
    if (!(entity in entities)) throw new Error(`Unsupported source entity: ${all}`);
    return entities[entity];
  });
  const input = source.replace(/<!--[\s\S]*?-->/g, "").replace(/<span\b[^>]*aria-hidden="true"[^>]*>[\s\S]*?<\/span>/g, "");
  const allowed = new Set(["main", "div", "section", "nav", "article", "aside", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "a", "span", "strong", "b", "em", "i", "code", "br", "time"]);
  const stack = [];
  let output = "";
  for (const token of input.match(/<[^>]+>|[^<]+/g) || []) {
    if (!token.startsWith("<")) { output += decode(token.replace(/\s+/g, " ")); continue; }
    const match = /^<(\/)?([a-z][a-z0-9]*)\b([^>]*)>/i.exec(token);
    if (!match || !allowed.has(match[2])) throw new Error(`Unsupported public source markup: ${token}`);
    const [, closing, tag, attributes] = match;
    if (tag === "br") { output += "\n"; continue; }
    if (closing) {
      const open = stack.pop();
      if (open?.tag !== tag) throw new Error(`Unbalanced public source tag: ${tag}`);
      if (tag === "a") output = output.trimEnd() + `](${open.href})`;
      else if (["strong", "b"].includes(tag)) output = output.trimEnd() + "**";
      else if (["em", "i"].includes(tag)) output = output.trimEnd() + "*";
      else if (tag === "code") output = output.trimEnd() + "`";
      else if (/^h[1-6]$/.test(tag) || ["p", "div", "section", "main", "nav", "article", "aside", "ul", "ol"].includes(tag)) output += "\n\n";
      else if (tag === "li") output += "\n";
    } else {
      const href = /\bhref=["']([^"']+)["']/.exec(attributes)?.[1];
      stack.push({ tag, href: href ? new URL(decode(href), origin).href : undefined });
      if (tag === "a") { if (!href) throw new Error("Source content link requires href"); output += "["; }
      else if (/^h[1-6]$/.test(tag)) output += `\n\n${"#".repeat(Math.max(2, Number(tag[1])))} `;
      else if (tag === "li") output += "\n- ";
      else if (["p", "div", "section", "main", "nav", "article", "aside", "ul", "ol"].includes(tag)) output += "\n\n";
      else if (["strong", "b"].includes(tag)) output += "**";
      else if (["em", "i"].includes(tag)) output += "*";
      else if (tag === "code") output += "`";
    }
  }
  if (stack.length) throw new Error("Unclosed public content source tags");
  return output.replace(/[ \t]+\n/g, "\n").replace(/\n[ \t]+/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}
