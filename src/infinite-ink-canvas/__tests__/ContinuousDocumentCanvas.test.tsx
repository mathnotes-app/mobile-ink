import React from 'react';
import { act, render } from '@testing-library/react-native';
import { ContinuousDocumentCanvas, type ContinuousDocumentCanvasRef } from '../ContinuousDocumentCanvas';

const mockLoad = jest.fn(async (_payloads: string[], _height: number) => true);
const mockCapture = jest.fn(async (_count: number, _height: number) => ['first', 'second']);
const mockClear = jest.fn();
const mockRecordExternal = jest.fn(async () => true);
let mockProps: any;
let mockViewportProps: any;
jest.mock('react-native-gesture-handler', () => ({ GestureHandlerRootView: require('react-native').View }));
jest.mock('../PageStack', () => ({ PageBackgrounds: () => null, PageBreaks: () => null }));
jest.mock('../../ZoomableInkViewport', () => ({ __esModule: true,
  default: require('react').forwardRef((props: any, ref: any) => {
    mockViewportProps = props;
    require('react').useImperativeHandle(ref, () => ({ setTransform: jest.fn() }));
    return <>{props.children}</>;
  }),
}));
jest.mock('../../NativeInkCanvas', () => ({
  NativeInkCanvas: require('react').forwardRef((props: any, ref: any) => {
    mockProps = props;
    require('react').useImperativeHandle(ref, () => ({ loadDocument: mockLoad, captureDocument: mockCapture,
      setTool: jest.fn(), clearDocumentPage: mockClear, recordExternalEdit: mockRecordExternal }));
    require('react').useEffect(() => { props.onCanvasReady(); }, [props.onCanvasReady]);
    return null;
  }),
}));
const data = { version: '1.0' as const, originalCanvasWidth: 600, pages: [
  { id: 'a', title: 'A', rotation: 0, data: '{"pages":{}}' },
  { id: 'b', title: 'B', rotation: 0, data: '{"pages":{}}' },
] };
async function setup() {
  const ref = React.createRef<ContinuousDocumentCanvasRef>();
  const changed = jest.fn();
  const tree = render(<ContinuousDocumentCanvas ref={ref} initialData={data} pageHeight={1000}
      onDrawingChange={changed} toolState={{ toolType: 'pen', width: 2, color: '#000000', eraserMode: 'pixel' }} />);
  await act(async () => {});
  return { ref, changed, tree: tree! };
}
beforeEach(() => { jest.clearAllMocks(); });
it('retains blank pages and captures the whole document in order', async () => {
  const { ref, tree } = await setup();
  expect(mockLoad.mock.calls[0][0]).toHaveLength(2);
  act(() => mockProps.onDrawingChange());
  const result = await ref.current!.getNotebookData();
  expect(result.pages.map(p => p.data)).toEqual(['first', 'second']);
  expect(mockCapture).toHaveBeenCalledWith(2, 1000 * require('react-native').PixelRatio.get());
  expect(result.originalCanvasWidth).toBe(600);
  tree.unmount();
});
it('rejects a save whose document changed during native capture', async () => {
  const { ref, tree } = await setup();
  let resolve!: (value: string[]) => void;
  mockCapture.mockImplementationOnce(() => new Promise<string[]>(done => { resolve = done; }));
  act(() => mockProps.onDrawingChange());
  const save = ref.current!.getNotebookData();
  mockProps.onDrawingChange();
  resolve(['first', 'second']);
  await expect(save).rejects.toBeInstanceOf(require('../ContinuousDocumentCanvas').DocumentChangedDuringCaptureError);
  tree.unmount();
});
it('uses point coordinates for the drawing owner and native coordinates for page clear', async () => {
  const { ref, changed, tree } = await setup();
  act(() => {
    mockProps.onDrawingBegin({ nativeEvent: { x: 10, y: 1100 } });
    mockProps.onDrawingChange();
  });
  expect(changed).toHaveBeenCalledWith('b');
  act(() => ref.current!.scrollToPage(1));
  ref.current!.clearCurrentPage();
  expect(mockClear.mock.calls[0][0]).toBe(1);
  expect(mockClear.mock.calls[0][1]).toBe(1000 * require('react-native').PixelRatio.get());
  tree.unmount();
});

it('waits for native layout instead of abandoning the first document load', async () => {
  mockLoad.mockResolvedValueOnce(false).mockResolvedValueOnce(true);
  const ref = React.createRef<ContinuousDocumentCanvasRef>();
  const loaded = jest.fn();
  const tree = render(<ContinuousDocumentCanvas ref={ref} initialData={data} onReady={loaded}
    toolState={{ toolType: 'pen', width: 2, color: '#000000', eraserMode: 'pixel' }} />);
  await act(async () => { await new Promise<void>(resolve => setTimeout(resolve, 70)); });
  expect(loaded).toHaveBeenCalledTimes(1);
  expect(mockLoad).toHaveBeenCalledTimes(2);
  tree.unmount();
});

it('adds one trailing blank page after writing on the last page without growing on undo notifications', async () => {
  const { ref, tree } = await setup();
  act(() => {
    mockProps.onDrawingBegin({ nativeEvent: { x: 10, y: 1100 } });
    mockProps.onDrawingChange();
    mockProps.onDrawingChange();
  });
  mockCapture.mockResolvedValueOnce(['first', 'second', '{"pages":{}}']);
  const saved = await ref.current!.getNotebookData();
  expect(saved.pages).toHaveLength(3);
  expect(saved.pages[0].id).toBe('a');
  expect(saved.pages[1].id).toBe('b');
  tree.unmount();
});

it('blocks drawing and overlays until document replacement completes', async () => {
  const { ref, tree } = await setup();
  let finish!: (value: boolean) => void;
  mockLoad.mockImplementationOnce(() => new Promise<boolean>(resolve => { finish = resolve; }));
  let load!: Promise<void>;
  act(() => { load = ref.current!.loadNotebookData(data); });
  expect(tree.getByTestId('continuous-document-input').props.pointerEvents).toBe('none');
  await act(async () => { finish(true); await load; });
  expect(tree.getByTestId('continuous-document-input').props.pointerEvents).toBe('auto');
  tree.unmount();
});

it('does not serialize unchanged ink on repeated saves, but invalidates after editing', async () => {
  const { ref, tree } = await setup();
  await ref.current!.getNotebookData();
  await ref.current!.getNotebookData();
  expect(mockCapture).not.toHaveBeenCalled();
  act(() => mockProps.onDrawingChange());
  const saved = await ref.current!.getNotebookData();
  expect(mockCapture).toHaveBeenCalledTimes(1);
  expect(await ref.current!.getNotebookData()).toEqual(saved);
  expect(mockCapture).toHaveBeenCalledTimes(1);
  act(() => mockProps.onDrawingBegin({ nativeEvent: { x: 2, y: 5 } }));
  await ref.current!.getNotebookData();
  expect(mockCapture).toHaveBeenCalledTimes(2);
  tree.unmount();
});

it('routes external undo patches without dirtying ink or appending a page', async () => {
  const ref = React.createRef<ContinuousDocumentCanvasRef>();
  const external = jest.fn();
  const changed = jest.fn();
  const history = jest.fn();
  const tree = render(<ContinuousDocumentCanvas ref={ref} initialData={data}
    onExternalEdit={external} onDrawingChange={changed} onHistoryAction={history}
    toolState={{ toolType: 'pen', width: 2, color: '#000000', eraserMode: 'pixel' }} />);
  await act(async () => {});
  await expect(ref.current!.recordExternalEdit('before', 'after')).resolves.toBe(true);
  expect(mockRecordExternal).toHaveBeenCalledWith('before', 'after');
  act(() => mockProps.onDrawingChange({ nativeEvent: { historyAction: "undo", externalEdit: { payload: 'before' } } }));
  expect(external).toHaveBeenCalledWith('before');
  expect(history).toHaveBeenCalledWith('undo');
  expect(history.mock.invocationCallOrder[0]).toBeGreaterThan(external.mock.invocationCallOrder[0]);
  expect(changed).not.toHaveBeenCalled();
  expect((await ref.current!.getNotebookData()).pages).toHaveLength(2);
  expect(mockCapture).not.toHaveBeenCalled();
  tree.unmount();
});

it('keeps persistence blocked after a failed replacement until a successful retry', async () => {
  const {ref, tree} = await setup();
  mockLoad.mockRejectedValueOnce(new Error('native load failed'));
  await act(async () => {
    await expect(ref.current!.loadNotebookData(data)).rejects.toThrow('native load failed');
  });
  expect(tree.getByTestId('continuous-document-input').props.pointerEvents).toBe('none');
  await expect(ref.current!.getNotebookData()).rejects.toThrow('not ready');
  await act(async () => { await ref.current!.loadNotebookData(data); });
  expect(tree.getByTestId('continuous-document-input').props.pointerEvents).toBe('auto');
  await expect(ref.current!.getNotebookData()).resolves.toMatchObject({pages: expect.any(Array)});
  tree.unmount();
});

it('does not reparse the initial notebook when tools or viewport state rerender it', async () => {
  const raw = JSON.stringify(data);
  const parse = jest.spyOn(JSON, 'parse');
  const tool = {toolType: 'pen' as const, width: 2, color: '#000000', eraserMode: 'pixel' as const};
  const tree = render(<ContinuousDocumentCanvas initialData={raw} toolState={tool} />);
  await act(async () => {});
  const initialCalls = parse.mock.calls.filter(([input]) => input === raw).length;
  expect(initialCalls).toBeGreaterThan(0);
  for (const width of [3, 4, 5]) {
    tree.rerender(<ContinuousDocumentCanvas initialData={raw} toolState={{...tool, width}} />);
    await act(async () => {});
  }
  expect(parse.mock.calls.filter(([input]) => input === raw)).toHaveLength(initialCalls);
  tree.unmount();
  parse.mockRestore();
});

it('excludes host overlay gestures from viewport panning while keeping blank margins available', async () => {
  const blockedTouchRects = [{left: 100, top: 200, right: 400, bottom: 500}];
  const tree = render(<ContinuousDocumentCanvas initialData={data} blockedTouchRects={blockedTouchRects}
    toolState={{toolType: 'pen', width: 2, color: '#000000', eraserMode: 'pixel'}} />);
  await act(async () => {});
  expect(mockViewportProps.blockedTouchRects).toEqual(blockedTouchRects);
  expect(mockViewportProps.singleFingerPanBlocked).toBe(false);
  tree.unmount();
});
