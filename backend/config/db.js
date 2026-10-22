const mongoose = require('mongoose');
const colors = require('colors');

/**
 * Resolve the MongoDB connection string in a backwards-compatible way.
 * The original project shipped `MONGO_URI` in its .env.example but read
 * `MONGO_URL` in code. We accept both, preferring MONGO_URI.
 */
const getMongoUri = () => process.env.MONGO_URI || process.env.MONGO_URL;

const connectDB = async () => {
  const uri = getMongoUri();
  if (!uri) {
    throw new Error('MONGO_URI (or MONGO_URL) is not set');
  }

  mongoose.set('strictQuery', true);

  try {
    const conn = await mongoose.connect(uri, {
      serverSelectionTimeoutMS: 10000,
    });
    console.log(`MongoDB Connected successfully: ${conn.connection.host}`.cyan.underline);
    return conn;
  } catch (error) {
    console.error(`Error: ${error.message}`.red.underline.bold);
    throw error;
  }
};

module.exports = connectDB;
module.exports.getMongoUri = getMongoUri;
