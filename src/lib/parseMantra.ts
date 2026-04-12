export interface ParsedMantra {
  title: string;
  subtitle: string | null;
}

export function parseMantra(raw: string): ParsedMantra {
  // Require whitespace after a leading "-" or "*" so markdown bold ("**text**")
  // does not get its first star stripped off.
  const stripped = raw.replace(/^[-*]\s+/, "").trim();

  const boldMatch = stripped.match(/^\*\*(.+?)\*\*\s*[—–-]\s*(.+)$/);
  if (boldMatch) {
    return { title: boldMatch[1].trim(), subtitle: boldMatch[2].trim() };
  }

  const dashMatch = stripped.match(/^(.+?)\s*[—–]\s*(.+)$/);
  if (dashMatch) {
    return { title: dashMatch[1].trim(), subtitle: dashMatch[2].trim() };
  }

  return { title: stripped, subtitle: null };
}