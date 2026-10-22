#!/usr/bin/env node
/**
 * Seed an administrator account.
 *
 * Usage:
 *   ADMIN_EMAIL=admin@example.com ADMIN_PASSWORD='ChangeMe123!' npm run seed:admin
 *
 * Safe to run repeatedly: if the user exists it is promoted to admin instead
 * of being duplicated.
 */
require('dotenv').config();

const mongoose = require('mongoose');
const connectDB = require('../config/db');
const User = require('../models/userModel');

const run = async () => {
  const email = (process.env.ADMIN_EMAIL || '').toLowerCase().trim();
  const password = process.env.ADMIN_PASSWORD;
  const name = process.env.ADMIN_NAME || 'Administrator';

  if (!email || !password) {
    console.error('ADMIN_EMAIL and ADMIN_PASSWORD must be set');
    process.exit(1);
  }
  if (password.length < 6) {
    console.error('ADMIN_PASSWORD must be at least 6 characters');
    process.exit(1);
  }

  await connectDB();

  let user = await User.findOne({ email });
  if (user) {
    user.isAdmin = true;
    user.name = user.name || name;
    await user.save();
    console.log(`Existing user ${email} promoted to admin`);
  } else {
    user = await User.create({ name, email, password, isAdmin: true });
    console.log(`Admin user created: ${email}`);
  }

  await mongoose.connection.close();
  process.exit(0);
};

run().catch(async (err) => {
  console.error('Seed failed:', err.message);
  try {
    await mongoose.connection.close();
  } catch (_) {
    // ignore
  }
  process.exit(1);
});
