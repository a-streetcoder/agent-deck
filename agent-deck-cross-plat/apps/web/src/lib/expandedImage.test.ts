import { describe, expect, it } from "vitest";
import { buildExpandedImagePreview, type PreviewableImage } from "./expandedImage.ts";

const img = (id: string): PreviewableImage => ({
  id,
  name: `${id}.png`,
  mimeType: "image/png",
  data: `DATA_${id}`,
});

describe("buildExpandedImagePreview", () => {
  it("centers on the selected image and builds data URIs", () => {
    const preview = buildExpandedImagePreview([img("a"), img("b"), img("c")], "b");
    expect(preview).not.toBeNull();
    expect(preview!.index).toBe(1);
    expect(preview!.images).toHaveLength(3);
    expect(preview!.images[1]).toEqual({
      src: "data:image/png;base64,DATA_b",
      name: "b.png",
    });
  });

  it("returns null when the selected id is absent", () => {
    expect(buildExpandedImagePreview([img("a")], "missing")).toBeNull();
  });

  it("returns null for an empty set", () => {
    expect(buildExpandedImagePreview([], "a")).toBeNull();
  });
});
