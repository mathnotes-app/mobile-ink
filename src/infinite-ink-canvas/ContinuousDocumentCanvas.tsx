import React, { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from 'react';
import { PixelRatio, StyleSheet, View } from 'react-native';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { NativeInkCanvas, type NativeInkCanvasRef } from '../NativeInkCanvas';
import ZoomableInkViewport, { type ZoomableInkViewportRef, type TouchExclusionRect } from '../ZoomableInkViewport';
import { waitForNextFrame } from '../continuous-engine-pool/helpers';
import type { NotebookPage, SerializedNotebookData } from '../types';
import type { InfiniteInkCanvasProps, InfiniteInkCanvasRef, InfiniteInkViewportTransform } from './types';
import { DEFAULT_CONTENT_PADDING, DEFAULT_PAGE_HEIGHT, DEFAULT_PAGE_WIDTH } from './constants';
import { clonePage, getVisiblePageIndex, parseNotebookData } from './notebookPages';
import { createBlankPage, BLANK_PAGE_PAYLOAD, pageHasContent, pageHasPdfBackground } from '../utils/pageGrowth';
import { getRevealTranslateY, getRevealTargetScreenY } from '../utils/viewportTransform';
import { resolveDocumentRenderTarget, type DocumentRenderTarget } from '../utils/documentRenderTarget';
import { computeDataSignature } from '../utils/dataSignature';
import { PageBackgrounds, PageBreaks } from './PageStack';
import { selectionBoundsToTouchRect } from './selectionTouchRects';
import { styles } from './styles';

export type ContinuousDocumentCanvasRef = InfiniteInkCanvasRef & {
  recordExternalEdit: (before: string, after: string) => Promise<boolean>;
};
export type ContinuousDocumentCanvasProps = InfiniteInkCanvasProps & {
  /** Apply this host-owned overlay patch after a native undo/redo. */
  onExternalEdit?: (payload: string) => void;
  /** Called after the corresponding ink/overlay update has been delivered. */
  onHistoryAction?: (action: "undo" | "redo") => void;
};

/**
 * A save was superseded: ink or pages changed while it captured. Nothing is
 * wrong with the document; the change that superseded it should save again.
 */
export class DocumentChangedDuringCaptureError extends Error {
  constructor() {
    super('Document changed during capture; retry saving its current state');
    this.name = 'DocumentChangedDuringCaptureError';
  }
}

/** Checks by name so it also holds when Error subclasses are transpiled. */
export const isDocumentCaptureSuperseded = (error: unknown): boolean =>
  error instanceof Error && error.name === 'DocumentChangedDuringCaptureError';

// Page payloads retain whole crossing strokes and global drawing order. All
// pages are captured together; committing a dirty subset would corrupt order.
export const ContinuousDocumentCanvas = forwardRef<ContinuousDocumentCanvasRef, ContinuousDocumentCanvasProps>(function ContinuousDocumentCanvas(props, ref) {
  const { pageWidth = DEFAULT_PAGE_WIDTH, pageHeight = DEFAULT_PAGE_HEIGHT,
    contentPadding = DEFAULT_CONTENT_PADDING, toolState } = props;
  const originalWidth = useRef(pageWidth);
  const [pages, setPages] = useState<NotebookPage[]>(() => {
    const initial = parseNotebookData(props.initialData);
    originalWidth.current = initial?.originalCanvasWidth ?? pageWidth;
    return initial?.pages.length ? initial.pages.map(clonePage)
      : Array.from({ length: Math.max(1, props.initialPageCount ?? 2) }, (_, i) => createBlankPage(i));
  });
  const pagesRef = useRef(pages);
  const canvas = useRef<NativeInkCanvasRef>(null);
  const viewport = useRef<ZoomableInkViewportRef>(null);
  const callbacks = useRef(props); callbacks.current = props;
  const ready = useRef(false);
  const [inputReady, setInputReady] = useState(false);
  const initializing = useRef(false);
  const mounted = useRef(true);
  const currentPage = useRef(0);
  const drawingPage = useRef(0);
  const revision = useRef(0);
  const captured = useRef<{ revision: number; data: SerializedNotebookData } | null>(null);
  const appendAfterStroke = useRef(false);
  const dirtyPages = useRef(new Set<string>());
  const [visiblePage, setVisiblePage] = useState(0);
  // Viewport updates arrive every frame; only a changed render target may
  // re-render this tree or the native surface (see resolveDocumentRenderTarget).
  const transformRef = useRef<InfiniteInkViewportTransform | null>(null);
  const isMoving = useRef(false);
  const renderLayout = useCallback(() => ({ pageWidth, pageHeight, pageCount: pagesRef.current.length, contentPadding }),
    [contentPadding, pageHeight, pageWidth]);
  const [renderTarget, setRenderTarget] = useState<DocumentRenderTarget>(
    () => resolveDocumentRenderTarget(null, null, renderLayout(), false));
  const [selectionRects, setSelectionRects] = useState<TouchExclusionRect[]>([]);
  const documentHeight = pages.length * pageHeight;
  const density = PixelRatio.get();
  const report = useCallback((error: unknown) => {
    const failure = error instanceof Error ? error : new Error(String(error));
    console.error('[ContinuousDocumentCanvas]', failure);
    callbacks.current.onError?.(failure);
  }, []);
  const replacePages = useCallback((next: NotebookPage[]) => {
    pagesRef.current = next;
    setPages(next);
    callbacks.current.onPagesChange?.(next);
  }, []);
  const applyTool = useCallback(() => {
    const tool = callbacks.current.toolState;
    canvas.current?.setTool(tool.toolType, tool.width, tool.color, tool.eraserMode);
  }, []);
  useEffect(() => { if (ready.current) applyTool(); }, [toolState, applyTool]);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; ready.current = false; revision.current++; };
  }, []);

  const load = useCallback(async (data: SerializedNotebookData | string) => {
    if (initializing.current) throw new Error('Document load is already in progress');
    const parsed = parseNotebookData(data);
    if (!parsed?.pages.length) throw new Error('Cannot load a document without pages');
    const next = parsed.pages.map(clonePage);
    initializing.current = true;
    ready.current = false;
    setInputReady(false);
    try {
      // Compose before altering the mounted document; malformed data cannot
      // replace a good notebook with blank ink.
      const pagePayloads = next.map(p => p.data ?? BLANK_PAGE_PAYLOAD);
      if (!mounted.current || !canvas.current) throw new Error('Document canvas was unmounted');
      let loaded = false;
      for (let attempt = 0; attempt < 90 && !loaded; attempt++) {
        if (!mounted.current || !canvas.current) throw new Error('Document canvas was unmounted');
        loaded = await canvas.current.loadDocument(pagePayloads, pageHeight * density);
        if (!loaded) await waitForNextFrame();
      }
      if (!loaded) throw new Error('Native document load failed');
      if (!mounted.current) throw new Error('Document canvas was unmounted');
      revision.current++;
      originalWidth.current = parsed.originalCanvasWidth ?? pageWidth;
      dirtyPages.current.clear();
      appendAfterStroke.current = false;
      replacePages(next);
      captured.current = { revision: revision.current, data: { version: '1.0', pages: next, originalCanvasWidth: originalWidth.current } };
      currentPage.current = Math.min(currentPage.current, next.length - 1);
      ready.current = true;
      setInputReady(true);
      applyTool();
    } catch (error) {
      // A native failure may follow partial canvas replacement. Keep input
      // and persistence blocked until a confirmed load restores consistency.
      ready.current = false;
      if (mounted.current) setInputReady(false);
      throw error;
    } finally { initializing.current = false; }
  }, [applyTool, density, pageHeight, pageWidth, replacePages]);
  const onReady = useCallback(() => {
    if (ready.current || initializing.current) return;
    void load({ version: "1.0", pages: pagesRef.current, originalCanvasWidth: originalWidth.current })
      .then(() => callbacks.current.onReady?.()).catch(report);
  }, [load, report]);
  const capture = useCallback(async (): Promise<SerializedNotebookData> => {
    const native = canvas.current;
    if (!ready.current || !native) throw new Error('Document is not ready to save');
    const version = revision.current;
    if (captured.current?.revision === version) {
      const snapshot = captured.current.data;
      return { ...snapshot, pages: snapshot.pages.map(page => ({ ...page })) };
    }
    const source = pagesRef.current;
    const partitions = await native.captureDocument(source.length, pageHeight * density);
    if (!mounted.current || !ready.current || native !== canvas.current || version !== revision.current || source !== pagesRef.current)
      throw new DocumentChangedDuringCaptureError();
    if (partitions.length !== source.length) throw new Error('Incomplete document partition');
    const capturedPages = source.map((page, i) => ({ ...page, data: partitions[i], dataSignature: computeDataSignature(partitions[i]),
      previewUri: undefined, previewDataSignature: undefined }));
    const data: SerializedNotebookData = { version: '1.0', pages: capturedPages, originalCanvasWidth: originalWidth.current };
    captured.current = { revision: version, data };
    return { ...data, pages: data.pages.map(page => ({ ...page })) };
  }, [density, pageHeight]);
  const scrollToPage = useCallback((index: number, animated = true) => {
    const bounded = Math.max(0, Math.min(pagesRef.current.length - 1, index));
    currentPage.current = bounded; setVisiblePage(bounded);
    callbacks.current.onCurrentPageChange?.(bounded);
    viewport.current?.setTransform({ scale: 1, translateX: 0, translateY: -(bounded * pageHeight + contentPadding), animated });
  }, [contentPadding, pageHeight]);
  const addPage = useCallback(async (options?: { force?: boolean; scroll?: boolean }) => {
    if (!ready.current) throw new Error('Document is not ready to add a page');
    const last = pagesRef.current[pagesRef.current.length - 1];
    if (!options?.force && last && !pageHasContent(last, dirtyPages.current)) {
      if (options?.scroll !== false) scrollToPage(pagesRef.current.length - 1);
      return;
    }
    const next = [...pagesRef.current, createBlankPage(pagesRef.current.length)];
    revision.current++;
    replacePages(next);
    if (options?.scroll !== false) scrollToPage(next.length - 1);
  }, [replacePages, scrollToPage]);
  useImperativeHandle(ref, () => ({
    getNotebookData: capture, loadNotebookData: load, addPage,
    recordExternalEdit: (before, after) => ready.current && canvas.current
      ? canvas.current.recordExternalEdit(before, after) : Promise.resolve(false),
    undo: () => { if (ready.current) canvas.current?.undo(); },
    redo: () => { if (ready.current) canvas.current?.redo(); },
    clearCurrentPage: () => { if (ready.current) canvas.current?.clearDocumentPage(currentPage.current, pageHeight * density); },
    setTool: tool => canvas.current?.setTool(tool.toolType, tool.width, tool.color, tool.eraserMode),
    getCurrentPageIndex: () => currentPage.current,
    resetViewport: (animated = true) => animated ? viewport.current?.resetZoomAnimated() : viewport.current?.resetZoom(),
    scrollToPage,
    revealPagePosition: (index, y, animated = true) => {
      const t = viewport.current?.getTransform();
      if (!t) return;
      const bounded = Math.max(0, Math.min(pagesRef.current.length - 1, index));
      viewport.current?.setTransform({ translateY: getRevealTranslateY(contentPadding + bounded * pageHeight + y,
        getRevealTargetScreenY(t.containerHeight), t.scale, t.containerHeight), animated });
    },
    startBenchmarkRecording: async options => {
      if (!canvas.current?.startBenchmarkRecording) throw new Error('Native recorder unavailable');
      return canvas.current.startBenchmarkRecording(options);
    },
    stopBenchmarkRecording: async () => {
      if (!canvas.current?.stopBenchmarkRecording) throw new Error('Native recorder unavailable');
      return canvas.current.stopBenchmarkRecording();
    },
  }), [addPage, capture, contentPadding, density, load, pageHeight, scrollToPage]);
  const updateRenderTarget = useCallback(() => {
    const layout = renderLayout();
    setRenderTarget(previous => resolveDocumentRenderTarget(previous, transformRef.current, layout, isMoving.current));
  }, [renderLayout]);
  useEffect(updateRenderTarget, [pages.length, updateRenderTarget]);
  const onMotionStateChange = useCallback((moving: boolean) => {
    isMoving.current = moving;
    updateRenderTarget();
    callbacks.current.onMotionStateChange?.(moving);
  }, [updateRenderTarget]);
  const onTransform = useCallback((next: InfiniteInkViewportTransform) => {
    transformRef.current = next;
    updateRenderTarget();
    const index = getVisiblePageIndex(next, pageHeight, pagesRef.current.length, contentPadding);
    if (index !== currentPage.current) {
      currentPage.current = index; setVisiblePage(index);
      callbacks.current.onCurrentPageChange?.(index);
    }
    callbacks.current.onTransformChange?.(next);
  }, [contentPadding, pageHeight, updateRenderTarget]);
  return <GestureHandlerRootView style={[styles.root, props.style]}>
    <ZoomableInkViewport ref={viewport} style={styles.viewport} minScale={props.minScale ?? 1} maxScale={props.maxScale ?? 5}
      contentWidth={pageWidth} contentHeight={documentHeight} contentPadding={contentPadding} isLandscape
      fingerDrawingEnabled={props.fingerDrawingEnabled} enableMomentumScroll lockHorizontalPanNearFit
      blockedTouchRects={selectionRects} singleFingerPanBlocked={selectionRects.length > 0}
      transformNotificationMinIntervalMs={props.transformNotificationMinIntervalMs ?? 16}
      onTransformChange={onTransform} onMotionStateChange={onMotionStateChange}>
      <View style={[styles.canvasShell, { paddingTop: contentPadding, paddingBottom: contentPadding }]}>
        <View testID="continuous-document-input" pointerEvents={inputReady ? "auto" : "none"} style={{ width: pageWidth, height: documentHeight }}>
          <PageBackgrounds pages={pages} pageWidth={pageWidth} pageHeight={pageHeight} backgroundType={props.backgroundType ?? 'plain'}
            pdfBackgroundBaseUri={props.pdfBackgroundBaseUri} visiblePageIndex={visiblePage} showPageLabels={props.showPageLabels ?? true} />
          <NativeInkCanvas ref={canvas} style={StyleSheet.absoluteFillObject} continuousDocument backgroundType="pdf"
            renderBackend={props.renderBackend} renderScale={renderTarget.renderScale}
            renderViewportLeftRatio={renderTarget.leftRatio} renderViewportTopRatio={renderTarget.topRatio}
            renderViewportWidthRatio={renderTarget.widthRatio} renderViewportHeightRatio={renderTarget.heightRatio}
            drawingPolicy={props.fingerDrawingEnabled ? 'anyinput' : 'pencilonly'} onCanvasReady={onReady}
            onDrawingBegin={event => {
              revision.current++;
              drawingPage.current = Math.max(0, Math.min(pagesRef.current.length - 1, Math.floor(event.nativeEvent.y / pageHeight)));
              const last = pagesRef.current[pagesRef.current.length - 1];
              appendAfterStroke.current = drawingPage.current === pagesRef.current.length - 1 &&
                !pageHasPdfBackground(last) && ['pen', 'highlighter', 'crayon', 'calligraphy'].includes(callbacks.current.toolState.toolType);
            }}
            onDrawingChange={event => {
              if (!ready.current) return;
              const action = event?.nativeEvent.historyAction;
              const patch = event?.nativeEvent.externalEdit?.payload;
              if (patch !== undefined) {
                callbacks.current.onExternalEdit?.(patch);
                if (action) callbacks.current.onHistoryAction?.(action);
                return;
              }
              revision.current++;
              const page = pagesRef.current[drawingPage.current];
              if (page) dirtyPages.current.add(page.id);
              if (appendAfterStroke.current) {
                appendAfterStroke.current = false;
                replacePages([...pagesRef.current, createBlankPage(pagesRef.current.length)]);
              }
              if (page) callbacks.current.onDrawingChange?.(page.id);
              if (action) callbacks.current.onHistoryAction?.(action);
            }}
            onSelectionChange={({ nativeEvent: { count, bounds } }) => {
              const touchRect = selectionBoundsToTouchRect({ bounds: bounds ?? null, pageIndex: 0, pageWidth, pageHeight,
                contentPadding, containerWidth: transformRef.current?.containerWidth ?? pageWidth });
              setSelectionRects(count && touchRect ? [touchRect] : []);
              const index = bounds ? Math.max(0, Math.min(pagesRef.current.length - 1, Math.floor(bounds.y / pageHeight))) : currentPage.current;
              const page = pagesRef.current[index];
              if (page) callbacks.current.onSelectionChange?.(page.id, count, bounds ? { ...bounds, y: bounds.y - index * pageHeight } : null);
            }}
            onPencilDoubleTap={event => callbacks.current.onPencilDoubleTap?.(event)} />
          {props.overlay}
          <PageBreaks pages={pages} pageHeight={pageHeight} />
        </View>
      </View>
    </ZoomableInkViewport>
  </GestureHandlerRootView>;
});
