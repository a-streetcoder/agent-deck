/**
 * A session's shown title: pi's generated title once it exists, otherwise a
 * native-style "Draft · <project>" placeholder for an untitled draft.
 */
export function sessionDisplayTitle(title: string | undefined, projectName: string): string {
  const trimmed = title?.trim();
  return trimmed ? trimmed : `Draft · ${projectName}`;
}
