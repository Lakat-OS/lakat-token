// Minimal RFC 4180 CSV reader. No dependencies — the input here is a two-column
// allocations list, not arbitrary spreadsheet exports, so this stays small.

/** Split CSV text into rows of raw string fields. */
export function parseCsv(text, delimiter = ",") {
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1); // strip BOM

  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  let inQuotes = false;

  const endField = () => {
    row.push(quoted ? field : field.trim());
    field = "";
    quoted = false;
  };
  const endRow = () => {
    endField();
    rows.push(row);
    row = [];
  };

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c !== '"') field += c;
      else if (text[i + 1] === '"') (field += '"'), i++; // escaped quote
      else inQuotes = false;
    } else if (c === '"') {
      inQuotes = true;
      quoted = true;
    } else if (c === delimiter) {
      endField();
    } else if (c === "\n") {
      endRow();
    } else if (c !== "\r") {
      field += c;
    }
  }
  if (field !== "" || row.length > 0) endRow();

  // Drop blank lines and `#` comments.
  return rows.filter((r) => !(r.length === 1 && r[0] === "") && !r[0].startsWith("#"));
}

/** Guess the delimiter from the first non-comment line: `,` or `;`. */
export function sniffDelimiter(text) {
  const line = text.split("\n").find((l) => l.trim() && !l.trimStart().startsWith("#")) ?? "";
  const outside = line.replace(/"[^"]*"/g, ""); // ignore quoted sections
  return (outside.match(/;/g)?.length ?? 0) > (outside.match(/,/g)?.length ?? 0) ? ";" : ",";
}
