import type { NotebookPage } from "../types";

export const BLANK_PAGE_PAYLOAD = '{"pages":{}}';

export const createBlankPage = (pageIndex: number): NotebookPage => ({
  id: `page-${pageIndex + 1}-${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2, 8)}`,
  title: `Page ${pageIndex + 1}`,
  data: BLANK_PAGE_PAYLOAD,
  rotation: 0,
});

export const isBlankPagePayload = (data?: string) => {
  if (!data || data.trim().length === 0) {
    return true;
  }

  return data.trim() === BLANK_PAGE_PAYLOAD;
};

export const pageHasPdfBackground = (page: NotebookPage) => (
  typeof page.pdfPageNumber === "number" || page.pageType === "pdf"
);

export const pageHasContent = (
  page: NotebookPage,
  dirtyPageIds: Set<string> = new Set(),
) => {
  return (
    dirtyPageIds.has(page.id) ||
    !isBlankPagePayload(page.data) ||
    (Array.isArray(page.textBoxes) && page.textBoxes.length > 0) ||
    (Array.isArray(page.insertedElements) && page.insertedElements.length > 0) ||
    pageHasPdfBackground(page) ||
    page.graphState != null
  );
};

export const getLastContentPageIndex = (
  pages: NotebookPage[],
  dirtyPageIds: Set<string> = new Set(),
) => {
  for (let pageIndex = pages.length - 1; pageIndex >= 0; pageIndex -= 1) {
    if (pageHasContent(pages[pageIndex], dirtyPageIds)) {
      return pageIndex;
    }
  }

  return -1;
};

export const withSingleTrailingBlankPage = (
  pages: NotebookPage[],
  dirtyPageIds: Set<string> = new Set(),
) => {
  const sourcePages = pages.length > 0 ? pages : [createBlankPage(0)];
  const lastContentPageIndex = getLastContentPageIndex(sourcePages, dirtyPageIds);
  const lastContentPage = sourcePages[lastContentPageIndex];
  const needsTrailingBlank =
    !lastContentPage || !pageHasPdfBackground(lastContentPage);
  const desiredPageCount = Math.max(
    1,
    lastContentPageIndex + (needsTrailingBlank ? 2 : 1),
  );

  if (sourcePages.length === desiredPageCount) {
    return sourcePages;
  }

  const nextPages = sourcePages.slice(0, desiredPageCount);
  while (nextPages.length < desiredPageCount) {
    nextPages.push(createBlankPage(nextPages.length));
  }

  return nextPages;
};
