/**
 * Normalise an uploaded file reference into something the frontend can use
 * as an <img src>.
 *
 * - Cloudinary files expose `path` as an absolute https URL.
 * - Local disk files expose `filename`; we serve them from /uploads.
 */
const fileUrl = (file) => {
  if (!file) return undefined;
  if (typeof file === 'string') return file;
  if (file.path && /^https?:\/\//i.test(file.path)) return file.path;
  if (file.filename) return `/uploads/${file.filename}`;
  return undefined;
};

module.exports = fileUrl;
