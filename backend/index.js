const express = require('express');
const cors = require('cors');
const path = require('path');
const mongoose = require('mongoose');
require('dotenv').config();

const connectDB = require('./config/db');
const httpStatusText = require('./utils/httpStatusText');
const appError = require('./utils/appError');

const productRoutes = require('./routes/productRoutes');
const userRoutes = require('./routes/userRoutes');
const orderRoutes = require('./routes/orderRoutes');
const authRoutes = require('./routes/authRoutes');
const cartRoutes = require('./routes/cartRoutes');
const categoryRoutes = require('./routes/categoryRoutes');

const rateLimit = require('express-rate-limit');
const helmet = require('helmet');
const mongoSanitize = require('./middlewares/mongoSanitize');
const uploadMiddleware = require('./middlewares/uploadImage');

const app = express();
const PORT = Number(process.env.PORT) || 5000;
const HOST = process.env.HOST || '0.0.0.0';

// Behind Nginx / a load balancer, trust the first proxy hop so rate limiting
// and client IP logging behave correctly.
app.set('trust proxy', 1);

const allowedOrigins = process.env.CORS_ORIGIN
  ? process.env.CORS_ORIGIN.split(',').map((o) => o.trim()).filter(Boolean)
  : true;

app.use(cors({ origin: allowedOrigins, credentials: true }));

app.use(
  helmet({
    // Images are served from the same origin under /uploads by default.
    crossOriginResourcePolicy: { policy: 'cross-origin' },
  })
);

// Health check must be cheap and unaffected by the API rate limiter.
app.get('/api/health', (req, res) => {
  const dbConnected = mongoose.connection.readyState === 1;
  res.status(dbConnected ? 200 : 503).json({
    status: dbConnected ? httpStatusText.SUCCESS : httpStatusText.ERROR,
    message: dbConnected ? 'Service healthy' : 'Database unavailable',
    db: dbConnected ? 'connected' : 'disconnected',
    uploads: uploadMiddleware.useCloudinary ? 'cloudinary' : 'local-disk',
    uptime: Number(process.uptime().toFixed(2)),
    timestamp: new Date().toISOString(),
  });
});

const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: Number(process.env.RATE_LIMIT_MAX) || 300,
  standardHeaders: true,
  legacyHeaders: false,
  message: 'Too many requests from this IP, please try again later',
});
app.use('/api', limiter);

app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(mongoSanitize);

// Locally-stored product/user images (Cloudinary is used automatically when
// credentials are provided).
const uploadDir = path.resolve(process.env.UPLOAD_DIR || 'uploads');
app.use('/uploads', express.static(uploadDir, { maxAge: '1d' }));

app.use('/api/products', productRoutes);
app.use('/api/auth', authRoutes);
app.use('/api/users', userRoutes);
app.use('/api/orders', orderRoutes);
app.use('/api/cart', cartRoutes);
app.use('/api/categories', categoryRoutes);

// Unknown API routes
app.use((req, res, next) => {
  next(appError.create(`Route not found: ${req.originalUrl}`, 404, httpStatusText.FAIL));
});

// Global error handler
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const statusCode = err.statusCode || 500;
  if (statusCode >= 500) {
    console.error('Unhandled error:', err);
  }
  res.status(statusCode).json({
    status: err.statusText || httpStatusText.ERROR,
    message: statusCode >= 500 && process.env.NODE_ENV === 'production'
      ? 'Internal server error'
      : err.message,
    code: statusCode,
    data: null,
  });
});

let server;

const start = async () => {
  await connectDB();

  server = app.listen(PORT, HOST, () => {
    console.log(`Server is running on http://${HOST}:${PORT}`);
  });

  const shutdown = async (signal) => {
    console.log(`${signal} received: shutting down gracefully...`);
    try {
      if (server) {
        await new Promise((resolve) => server.close(resolve));
      }
      await mongoose.connection.close();
      console.log('Shutdown complete');
      process.exit(0);
    } catch (err) {
      console.error('Error during shutdown:', err);
      process.exit(1);
    }
  };

  ['SIGTERM', 'SIGINT'].forEach((signal) => {
    process.on(signal, () => shutdown(signal));
  });
};

if (require.main === module) {
  start().catch((err) => {
    console.error('Failed to start server:', err);
    process.exit(1);
  });
}

module.exports = app;
module.exports.start = start;
