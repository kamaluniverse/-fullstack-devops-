import { describe, it, expect } from 'vitest';
import axiosInstance from '@/services/axiosInstance';

describe('axiosInstance', () => {
  it('uses a relative /api base URL by default (no hardcoded host)', () => {
    // VITE_API_URL is unset during tests, so the fallback applies.
    expect(axiosInstance.defaults.baseURL).toBe('/api');
    expect(axiosInstance.defaults.baseURL).not.toMatch(/localhost|127\.0\.0\.1/);
  });
});
