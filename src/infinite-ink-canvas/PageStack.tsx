import React, { memo } from "react";
import { StyleSheet, Text, View } from "react-native";
import NativeInkPageBackground from "../NativeInkPageBackground";
import type { NotebookPage } from "../types";
import { getContinuousEnginePoolRange } from "../utils/continuousEnginePool";
import { styles } from "./styles";

const PDF_BACKGROUND_WINDOW_SIZE = 7;

export type PageBackgroundsProps = {
  pages: NotebookPage[];
  pageWidth: number;
  pageHeight: number;
  backgroundType: string;
  pdfBackgroundBaseUri?: string;
  showPageLabels: boolean;
  visiblePageIndex: number;
};

export const PageBackgrounds = memo(function PageBackgrounds({
  pages,
  pageWidth,
  pageHeight,
  backgroundType,
  pdfBackgroundBaseUri,
  showPageLabels,
  visiblePageIndex,
}: PageBackgroundsProps) {
  const shouldWindowPdfBackgrounds = backgroundType === "pdf";
  const renderRange = shouldWindowPdfBackgrounds
    ? getContinuousEnginePoolRange(
        visiblePageIndex,
        pages.length,
        PDF_BACKGROUND_WINDOW_SIZE,
      )
    : { startIndex: 0, endIndex: pages.length - 1 };
  const renderedPages = [];

  for (
    let pageIndex = renderRange.startIndex;
    pageIndex <= renderRange.endIndex;
    pageIndex += 1
  ) {
    const page = pages[pageIndex];
    if (page) {
      renderedPages.push({ page, pageIndex });
    }
  }

  return (
    <>
      {renderedPages.map(({ page, pageIndex }) => {
        const pdfBackgroundUri = backgroundType === "pdf" && pdfBackgroundBaseUri
          ? `${pdfBackgroundBaseUri}#page=${page.pdfPageNumber || pageIndex + 1}`
          : undefined;

        return (
          <View
            key={`mobile-ink-page-background-${page.id}`}
            pointerEvents="none"
            style={[
              styles.page,
              {
                top: pageIndex * pageHeight,
                width: pageWidth,
                height: pageHeight,
              },
            ]}
          >
            <NativeInkPageBackground
              style={StyleSheet.absoluteFillObject}
              backgroundType={backgroundType}
              pdfBackgroundUri={pdfBackgroundUri}
            />
            {showPageLabels ? (
              <Text style={styles.pageLabel}>{pageIndex + 1}</Text>
            ) : null}
          </View>
        );
      })}
    </>
  );
});

export type PageBreaksProps = {
  pages: NotebookPage[];
  pageHeight: number;
};

export const PageBreaks = memo(function PageBreaks({
  pages,
  pageHeight,
}: PageBreaksProps) {
  return (
    <>
      {pages.slice(1).map((page, pageIndex) => (
        <View
          key={`mobile-ink-page-break-${page.id}`}
          pointerEvents="none"
          style={[
            styles.pageBreak,
            { top: (pageIndex + 1) * pageHeight - StyleSheet.hairlineWidth / 2 },
          ]}
        />
      ))}
    </>
  );
});
