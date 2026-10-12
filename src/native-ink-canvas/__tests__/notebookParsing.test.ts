import {Platform} from 'react-native';
import {parseNotebookData} from '../notebookBridge';
import {MobileInkBridge, MobileInkModule} from '../nativeModules';
jest.mock('../nativeModules', () => ({
  MobileInkBridge: {parseNotebookData: jest.fn()},
  MobileInkModule: {parseNotebookData: jest.fn()},
}));
const originalOS = Platform.OS;
afterEach(() => {Platform.OS = originalOS; jest.resetAllMocks();});
for (const os of ['ios', 'android'] as const) {
  test(`${os} parses exactly the selected payload and propagates native failure`, async () => {
    Platform.OS = os;
    const method = os === 'ios' ? MobileInkBridge.parseNotebookData : MobileInkModule.parseNotebookData;
    const data = '{"version":"1.0","pages":[]}';
    method.mockResolvedValueOnce({version: '1.0', pages: []});
    expect(await parseNotebookData(data)).toEqual({version: '1.0', pages: []});
    expect(method).toHaveBeenCalledWith(data);
    method.mockRejectedValueOnce(new Error('invalid JSON'));
    await expect(parseNotebookData('broken')).rejects.toThrow('invalid JSON');
    method.mockResolvedValueOnce([]);
    await expect(parseNotebookData('[]')).rejects.toThrow('invalid root');
  });
}
test('unavailable platform returns null for the caller fallback', async () => {
  Platform.OS = 'web';
  expect(await parseNotebookData('{}')).toBeNull();
});
