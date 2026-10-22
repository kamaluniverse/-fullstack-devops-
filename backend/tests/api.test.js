const request = require('supertest');
const mongoose = require('mongoose');
const { MongoMemoryServer } = require('mongodb-memory-server');

let app;
let mongo;

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URI = mongo.getUri();
  process.env.MONGO_URL = mongo.getUri();
  process.env.JWT_SECRET = 'test-secret-do-not-use-in-production';
  process.env.NODE_ENV = 'test';

  await mongoose.connect(process.env.MONGO_URI, { serverSelectionTimeoutMS: 10000 });
  app = require('../index');
});

afterAll(async () => {
  await mongoose.connection.dropDatabase();
  await mongoose.connection.close();
  if (mongo) await mongo.stop();
});

describe('GET /api/health', () => {
  it('reports a connected database', async () => {
    const res = await request(app).get('/api/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.db).toBe('connected');
    expect(typeof res.body.uptime).toBe('number');
  });
});

describe('auth flow', () => {
  const user = { name: 'Test User', email: 'test@example.com', password: 'secret123' };

  it('registers a new user and returns a token', async () => {
    const res = await request(app).post('/api/auth/register').send(user);
    expect(res.status).toBe(201);
    expect(res.body.data.user.email).toBe(user.email);
    expect(res.body.data.user.isAdmin).toBe(false);
    expect(res.body.data.user.token).toBeTruthy();
  });

  it('rejects a duplicate email', async () => {
    const res = await request(app).post('/api/auth/register').send(user);
    expect(res.status).toBe(400);
  });

  it('logs in with valid credentials', async () => {
    const res = await request(app).post('/api/auth/login').send({
      email: user.email,
      password: user.password,
    });
    expect(res.status).toBe(200);
    expect(res.body.data.user.token).toBeTruthy();
  });

  it('rejects an invalid password', async () => {
    const res = await request(app).post('/api/auth/login').send({
      email: user.email,
      password: 'wrong-password',
    });
    expect(res.status).toBe(401);
  });
});

describe('products API', () => {
  it('returns an empty product list', async () => {
    const res = await request(app).get('/api/products');
    expect(res.status).toBe(200);
    expect(res.body.data.products).toEqual([]);
  });

  it('rejects unauthenticated product creation', async () => {
    const res = await request(app).post('/api/products').send({ title: 'Nope' });
    expect(res.status).toBe(401);
  });

  it('returns 404 for a missing product', async () => {
    const res = await request(app).get('/api/products/64b7f9c2f1a2b3c4d5e6f7a8');
    expect(res.status).toBe(404);
  });
});

describe('cart API', () => {
  let token;
  let product;

  beforeAll(async () => {
    const User = require('../models/userModel');
    const Category = require('../models/categoryModel');
    const Product = require('../models/productModel');

    const login = await request(app)
      .post('/api/auth/login')
      .send({ email: 'test@example.com', password: 'secret123' });
    token = login.body.data.user.token;

    const user = await User.findOne({ email: 'test@example.com' });
    const category = await Category.create({ title: 'Test Category' });
    product = await Product.create({
      user: user._id,
      title: 'Test Product',
      image: '/uploads/test.jpg',
      description: 'A product used by the cart tests',
      category: category._id,
      price: 10,
      countInStock: 5,
    });
  });

  it('adds an item to the cart', async () => {
    const res = await request(app)
      .post('/api/cart')
      .set('Authorization', `Bearer ${token}`)
      .send({ productId: product._id.toString(), quantity: 2 });

    expect(res.status).toBe(200);
    expect(res.body.data.cart.items).toHaveLength(1);
    expect(res.body.data.cart.totalPrice).toBe(20);
  });

  it('rejects a missing productId with 400', async () => {
    const res = await request(app)
      .post('/api/cart')
      .set('Authorization', `Bearer ${token}`)
      .send({});

    expect(res.status).toBe(400);
  });

  it('updates the item quantity', async () => {
    const res = await request(app)
      .patch('/api/cart/update')
      .set('Authorization', `Bearer ${token}`)
      .send({ productId: product._id.toString(), quantity: 3 });

    expect(res.status).toBe(200);
    expect(res.body.data.cart.totalPrice).toBe(30);
  });

  it('clears the cart', async () => {
    const res = await request(app)
      .delete('/api/cart/clear')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.data.cart.items).toHaveLength(0);
  });
});

describe('unknown routes', () => {
  it('returns a JSON 404', async () => {
    const res = await request(app).get('/api/does-not-exist');
    expect(res.status).toBe(404);
    expect(res.body.status).toBe('fail');
  });
});
