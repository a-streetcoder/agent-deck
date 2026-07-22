/**
 * Slice 17 — expanded image preview.
 *
 * Builds the data for the full-size image overlay from the composer's pending
 * images. Pure so the selection/navigation math is unit-tested without a DOM.
 * Ported from the donor's ExpandedImagePreview.buildExpandedImagePreview,
 * adapted to our pending-image shape (base64 `data` + `mimeType`, not a blob URL).
 */

export interface ExpandedImageItem {
  src: string;
  name: string;
}

export interface ExpandedImagePreview {
  images: ExpandedImageItem[];
  index: number;
}

export interface PreviewableImage {
  id: string;
  name: string;
  mimeType: string;
  data: string;
}

/**
 * The overlay preview centered on `selectedId`, or null if the id isn't among
 * the images (e.g. removed between click and render). Every image becomes a
 * `data:` src so the overlay is self-contained.
 */
export function buildExpandedImagePreview(
  images: ReadonlyArray<PreviewableImage>,
  selectedId: string,
): ExpandedImagePreview | null {
  const index = images.findIndex((image) => image.id === selectedId);
  if (index < 0) return null;
  return {
    images: images.map((image) => ({
      src: `data:${image.mimeType};base64,${image.data}`,
      name: image.name,
    })),
    index,
  };
}
