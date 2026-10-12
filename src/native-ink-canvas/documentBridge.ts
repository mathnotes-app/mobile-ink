import { NativeModules } from 'react-native';

interface DocumentBridge {
  loadDocument(viewTag: number, payloads: string[], pageHeight: number): Promise<boolean>;
  projectDocumentPages(payloads: string[], pageHeight: number, pageIndices: number[]): Promise<string[]>;
  composeDocument(payloads: string[], pageHeight: number): Promise<string>;
  partitionDocument(payload: string, pageCount: number, pageHeight: number): Promise<string[]>;
}
function bridge(): DocumentBridge {
  const native = NativeModules.MobileInkDocumentBridge as DocumentBridge | undefined;
  if (!native) throw new Error('MobileInkDocumentBridge is unavailable. Rebuild the app with the continuous document engine.');
  return native;
}
export function composeDocument(payloads: string[], pageHeight: number): Promise<string> {
  return bridge().composeDocument(payloads, pageHeight);
}
export function partitionDocument(payload: string, pageCount: number, pageHeight: number): Promise<string[]> {
  return bridge().partitionDocument(payload, pageCount, pageHeight);
}

/** Render-only payloads containing neighboring overflow. Do not save these. */
export function projectDocumentPages(payloads: string[], pageHeight: number, pageIndices: number[]): Promise<string[]> {
  return bridge().projectDocumentPages(payloads, pageHeight, pageIndices);
}

/** Compose and load without returning the combined document through JavaScript. */
export function loadDocument(viewTag: number, payloads: string[], pageHeight: number): Promise<boolean> {
  return bridge().loadDocument(viewTag, payloads, pageHeight);
}
