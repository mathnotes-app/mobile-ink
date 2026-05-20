import React from "react";
import { render } from "@testing-library/react-native";
import { PageBackgrounds } from "../infinite-ink-canvas/PageStack";
import type { NotebookPage } from "../types";

jest.mock("../NativeInkPageBackground", () => {
  const React = require("react");
  const { View } = require("react-native");

  return {
    __esModule: true,
    default: ({ backgroundType, pdfBackgroundUri }: {
      backgroundType?: string;
      pdfBackgroundUri?: string;
    }) => (
      <View
        testID="mock-page-background"
        accessibilityLabel={`${backgroundType ?? ""}:${pdfBackgroundUri ?? ""}`}
      />
    ),
  };
});

const pages = (count: number): NotebookPage[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `page-${index + 1}`,
    title: `Page ${index + 1}`,
    data: "",
    rotation: 0,
    pageType: "pdf",
    pdfPageNumber: index + 1,
  }));

describe("PageBackgrounds", () => {
  it("windows PDF backgrounds around the visible page", () => {
    const view = render(
      <PageBackgrounds
        pages={pages(100)}
        pageWidth={1200}
        pageHeight={1600}
        backgroundType="pdf"
        pdfBackgroundBaseUri="file:///large.pdf"
        showPageLabels={false}
        visiblePageIndex={50}
      />,
    );

    const backgrounds = view.getAllByTestId("mock-page-background");
    expect(backgrounds).toHaveLength(7);
    expect(backgrounds.map((background) => background.props.accessibilityLabel)).toEqual([
      "pdf:file:///large.pdf#page=48",
      "pdf:file:///large.pdf#page=49",
      "pdf:file:///large.pdf#page=50",
      "pdf:file:///large.pdf#page=51",
      "pdf:file:///large.pdf#page=52",
      "pdf:file:///large.pdf#page=53",
      "pdf:file:///large.pdf#page=54",
    ]);
  });

  it("keeps regular backgrounds fully rendered", () => {
    const view = render(
      <PageBackgrounds
        pages={pages(10)}
        pageWidth={1200}
        pageHeight={1600}
        backgroundType="lined"
        showPageLabels={false}
        visiblePageIndex={5}
      />,
    );

    expect(view.getAllByTestId("mock-page-background")).toHaveLength(10);
  });
});
