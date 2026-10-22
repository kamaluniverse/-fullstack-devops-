import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { Button } from '@/components/ui/button';

describe('Button', () => {
  it('renders its label and default variant attributes', () => {
    render(<Button>Add to cart</Button>);
    const btn = screen.getByRole('button', { name: /add to cart/i });
    expect(btn).toBeInTheDocument();
    expect(btn).toHaveAttribute('data-variant', 'default');
  });

  it('applies the requested variant', () => {
    render(<Button variant="destructive">Delete</Button>);
    expect(screen.getByRole('button', { name: /delete/i })).toHaveAttribute(
      'data-variant',
      'destructive'
    );
  });
});
