/**
 * Whether a path should offer the raw/preview markdown toggle (Slice L4a).
 * Ported verbatim from t3code's `filePreviewMode.ts` (MIT): `.md` / `.mdx`.
 */
export const isMarkdownPreviewFile = (path: string): boolean => /\.(?:md|mdx)$/i.test(path);
