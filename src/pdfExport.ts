import { NativeModules, Platform } from "react-native";
import { projectDocumentPages } from "./native-ink-canvas/documentBridge";

type Box = { x: number; y: number; width: number; height: number };
export type VectorPdfLayer =
  | { kind: "ink"; drawing: string }
  | ({ kind: "text"; text: string; fontSize: number; color: string; padding?: number } & Box)
  | ({ kind: "image"; uri: string; rotation?: number; crop?: Box; cornerRadius?: number } & Box)
  | { kind: "overlay"; uri: string };

export type VectorPdfPage = {
  width: number;
  height: number;
  density: number;
  pdfPage?: number;
  paper?: string;
  pageIndex?: number;
  layers: VectorPdfLayer[];
};

type NativeWriter = {
  begin(sourceUri: string | null): Promise<{ id: string; sourcePageCount: number }>;
  append(id: string, pages: VectorPdfPage[]): Promise<void>;
  finish(id: string): Promise<string>;
  cancel(id: string): Promise<void>;
};

export function supportsVectorPdfExport(): boolean {
  return Platform.OS === "ios" && !!NativeModules.MobileInkPdfExport?.begin;
}

/** Pulls one page at a time so inserted photos and raster effects stay bounded. */
export async function writeVectorPdf(
  sourceUri: string | null | undefined,
  pageCount: number,
  pageAt: (index: number, sourcePageCount: number) => Promise<VectorPdfPage>,
): Promise<string> {
  const writer = NativeModules.MobileInkPdfExport as NativeWriter | undefined;
  if (!supportsVectorPdfExport() || !writer) throw new Error("Vector PDF export requires the native iOS build");
  if (!Number.isInteger(pageCount) || pageCount < 1) throw new Error("Cannot export an empty notebook");
  const { id, sourcePageCount } = await writer.begin(sourceUri ?? null);
  try {
    for (let index = 0; index < pageCount; index++) {
      const page = await pageAt(index, sourcePageCount);
      await writer.append(id, [page]);
    }
    return await writer.finish(id);
  } catch (error) {
    await writer.cancel(id);
    throw error;
  }
}

/** Project a bounded range of pages while retaining ink that crosses page seams. */
export function createPdfInkProjector(payloads: string[], pageHeight: number): (index: number) => Promise<string> {
  const batchSize = 8;
  let start = -batchSize;
  let projected: string[] = [];
  return async (index) => {
    if (index < start || index >= start + projected.length) {
      start = index;
      const count = Math.min(batchSize, payloads.length - index);
      const indices = Array.from({ length: count }, (_, offset) => index + offset);
      projected = await projectDocumentPages(payloads, pageHeight, indices);
      if (projected.length !== indices.length) throw new Error("Incomplete PDF ink projection");
    }
    return projected[index - start];
  };
}
