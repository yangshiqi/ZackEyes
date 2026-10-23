// Released feature baseline and future journal plan; download metadata stays in release.mjs.
export const featureVersion = '0.10.0';
export const journalVersion = '0.11.0';
export const codexResetVersion = '0.10.2';

export function isCodexResetReleased(version) {
  const current = version.split('.').map(Number);
  const minimum = codexResetVersion.split('.').map(Number);
  for (let index = 0; index < minimum.length; index += 1) {
    if (current[index] !== minimum[index]) return current[index] > minimum[index];
  }
  return true;
}
