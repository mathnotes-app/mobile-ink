import type { NotebookPage } from "../types";
import {
  appendWritableBlankPage,
  BLANK_PAGE_PAYLOAD,
  withSingleTrailingBlankPage,
} from "../utils/pageGrowth";

const page = (
  id: string,
  data: string = BLANK_PAGE_PAYLOAD,
): NotebookPage => ({
  id,
  title: id,
  data,
  rotation: 0,
});

describe("withSingleTrailingBlankPage", () => {
  it("keeps one blank page for an empty notebook", () => {
    expect(withSingleTrailingBlankPage([])).toHaveLength(1);
    expect(withSingleTrailingBlankPage([page("page-1")])).toHaveLength(1);
  });

  it("adds exactly one blank page after the last content page", () => {
    const pages = withSingleTrailingBlankPage([
      page("page-1", '{"pages":{"page-1":{"strokes":[1]}}}'),
    ]);

    expect(pages).toHaveLength(2);
    expect(pages[0].id).toBe("page-1");
  });

  it("trims extra blank pages after content", () => {
    const pages = withSingleTrailingBlankPage([
      page("page-1", '{"pages":{"page-1":{"strokes":[1]}}}'),
      page("page-2"),
      page("page-3"),
      page("page-4"),
    ]);

    expect(pages.map((candidatePage) => candidatePage.id)).toEqual([
      "page-1",
      "page-2",
    ]);
  });

  it("treats a dirty page as content before it has serialized data", () => {
    const pages = withSingleTrailingBlankPage(
      [page("page-1")],
      new Set(["page-1"]),
    );

    expect(pages).toHaveLength(2);
  });

  it("keeps a trailing blank after text boxes or inserted elements", () => {
    const pages = withSingleTrailingBlankPage([
      {
        ...page("page-1"),
        textBoxes: [
          {
            id: "text",
            x: 0,
            y: 0,
            width: 100,
            content: "hi",
            color: "#000",
          },
        ],
      },
      {
        ...page("page-2"),
        insertedElements: [{ id: "image", type: "image", x: 0, y: 0 }],
      },
    ]);

    expect(pages).toHaveLength(3);
  });

  it("preserves every imported PDF page without appending a disposable blank", () => {
    const pages = withSingleTrailingBlankPage([
      { ...page("page-1"), pdfPageNumber: 1, pageType: "pdf" },
      { ...page("page-2"), pdfPageNumber: 2, pageType: "pdf" },
      { ...page("page-3"), pdfPageNumber: 3, pageType: "pdf" },
    ]);

    expect(pages.map((candidatePage) => candidatePage.id)).toEqual([
      "page-1",
      "page-2",
      "page-3",
    ]);
  });
});

describe("appendWritableBlankPage", () => {
  it("does not append after an unused trailing blank by default", () => {
    const pages = [page("page-1")];

    expect(appendWritableBlankPage(pages)).toEqual({
      pages,
      appendedPageId: null,
    });
  });

  it("keeps a force-appended page through normalization when retained", () => {
    const result = appendWritableBlankPage([page("page-1")], new Set(), true);
    expect(result.appendedPageId).not.toBeNull();

    const normalized = withSingleTrailingBlankPage(
      result.pages,
      new Set(),
      new Set([result.appendedPageId!]),
    );

    expect(normalized).toBe(result.pages);
    expect(normalized).toHaveLength(2);
    expect(normalized[1].id).toBe(result.appendedPageId);
  });
});
