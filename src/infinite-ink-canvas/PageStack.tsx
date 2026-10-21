import { resolveInkDisplayAppearance } from '../native-ink-canvas/nativeModules';
import React, { memo } from "react";
import { StyleSheet, Text, View } from "react-native";
import NativeInkPageBackground from "../NativeInkPageBackground";
import type { NotebookPage } from "../types";
import { getContinuousEnginePoolRange } from "../utils/continuousEnginePool";
import { styles } from "./styles";
import { INK_PAPER_COLORS, type InkDisplayAppearance } from '../displayAppearance';

const BACKGROUND_WINDOW_SIZE = 7;

export type PageBackgroundsProps = {
  displayAppearance?: InkDisplayAppearance;
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
  displayAppearance: requestedAppearance = 'light',
}: PageBackgroundsProps) {
  const displayAppearance = resolveInkDisplayAppearance(requestedAppearance);
  const renderRange = getContinuousEnginePoolRange(
    visiblePageIndex, pages.length, BACKGROUND_WINDOW_SIZE,
  );
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
      <View pointerEvents="none" style={[StyleSheet.absoluteFillObject, { backgroundColor: INK_PAPER_COLORS[displayAppearance] }]} />
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
                backgroundColor: INK_PAPER_COLORS[displayAppearance],
                top: pageIndex * pageHeight,
                width: pageWidth,
                height: pageHeight,
              },
            ]}
          >
            {backgroundType !== 'plain' && (
              <NativeInkPageBackground
                style={StyleSheet.absoluteFillObject}
                backgroundType={backgroundType}
                pdfBackgroundUri={pdfBackgroundUri}
                displayAppearance={displayAppearance}
              />
            )}
            {showPageLabels ? (
              <Text style={[styles.pageLabel, displayAppearance === 'dark' && { color: '#B5B5B5' }]}>{pageIndex + 1}</Text>
            ) : null}
          </View>
        );
      })}
    </>
  );
});

export type PageBreaksProps = {
  displayAppearance?: InkDisplayAppearance;
  pages: NotebookPage[];
  pageHeight: number;
};

export const PageBreaks = memo(function PageBreaks({
  displayAppearance = 'light',
  pages,
  pageHeight,
}: PageBreaksProps) {
  return (
    <>
      {pages.slice(1).map((page, pageIndex) => (
        <View
          key={`mobile-ink-page-break-${page.id}`}
          testID={`ink-page-boundary-${pageIndex + 1}`}
          collapsable={false}
          pointerEvents="none"
          style={[
            styles.pageBreak,
            displayAppearance === 'dark' && { backgroundColor: '#525252' },
            { top: (pageIndex + 1) * pageHeight - StyleSheet.hairlineWidth / 2 },
          ]}
        />
      ))}
    </>
  );
});
