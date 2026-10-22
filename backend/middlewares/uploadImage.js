const multer = require('multer');
const path = require('path');
const fs = require('fs');
const appError = require('../utils/appError');
const httpStatusText = require('../utils/httpStatusText');

/**
 * Image uploads are optional at the infrastructure level:
 *  - If Cloudinary credentials are present, uploads go to Cloudinary.
 *  - Otherwise they are written to a local directory (UPLOAD_DIR) and served
 *    by Express at /uploads. This keeps the stack fully functional on EC2
 *    without a third-party account.
 */
const useCloudinary = Boolean(
  process.env.CLOUDINARY_CLOUD_NAME &&
    process.env.CLOUDINARY_API_KEY &&
    process.env.CLOUDINARY_API_SECRET
);

let storage;

if (useCloudinary) {
  const cloudinary = require('cloudinary').v2;
  const { CloudinaryStorage } = require('multer-storage-cloudinary');

  cloudinary.config({
    cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
    api_key: process.env.CLOUDINARY_API_KEY,
    api_secret: process.env.CLOUDINARY_API_SECRET,
  });

  storage = new CloudinaryStorage({
    cloudinary,
    params: {
      folder: 'ecommerce-products',
      allowed_formats: ['jpg', 'png', 'jpeg', 'webp'],
    },
  });
} else {
  const uploadDir = path.resolve(process.env.UPLOAD_DIR || 'uploads');
  fs.mkdirSync(uploadDir, { recursive: true });

  storage = multer.diskStorage({
    destination: (req, file, cb) => cb(null, uploadDir),
    filename: (req, file, cb) => {
      const ext = path.extname(file.originalname).toLowerCase() || '.jpg';
      cb(null, `${Date.now()}-${Math.round(Math.random() * 1e9)}${ext}`);
    },
  });
}

const multerFilter = (req, file, cb) => {
  if (file.mimetype.startsWith('image')) {
    cb(null, true);
  } else {
    cb(appError.create('Not an image! Please upload only images.', 400, httpStatusText.FAIL), false);
  }
};

const upload = multer({
  storage,
  fileFilter: multerFilter,
  limits: { fileSize: 5 * 1024 * 1024 },
});

module.exports = upload;
module.exports.useCloudinary = useCloudinary;
