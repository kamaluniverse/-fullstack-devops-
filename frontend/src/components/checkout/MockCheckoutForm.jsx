import { useState } from "react";
import { useDispatch } from "react-redux";
import { useNavigate } from "react-router-dom";
import toast from "react-hot-toast";
import { CreditCard, ShieldCheck } from "lucide-react";

import { createOrder } from "@/services/orderService";
import { clearCart } from "@/store/slices/cartSlice";

/**
 * Demo checkout used when Stripe is not configured. It creates the order with
 * exactly the same payload shape as the Stripe flow, marking it as paid with a
 * synthetic payment result. See the README's "Payments" section.
 */
const MockCheckoutForm = ({ shippingData, totalAmount, items }) => {
  const dispatch = useDispatch();
  const navigate = useNavigate();
  const [isProcessing, setIsProcessing] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!items || items.length === 0) {
      toast.error("No items to order!");
      return;
    }

    setIsProcessing(true);
    try {
      const formattedOrderItems = items.map((item) => ({
        name: item?.product?.title,
        quantity: item.quantity,
        image: item?.product?.image,
        price: item?.product?.price,
        product: item.product?._id || item._id,
      }));

      const itemsPrice = formattedOrderItems.reduce(
        (acc, item) => acc + Number(item.price) * Number(item.quantity),
        0
      );
      const shippingPrice = itemsPrice > 500 ? 0 : 50;
      const taxPrice = itemsPrice * 0.1;

      await createOrder({
        orderItems: formattedOrderItems,
        shippingAddress: {
          address: shippingData.address,
          city: shippingData.city,
          postalCode: shippingData.postalCode,
          country: shippingData.country,
          phone: shippingData.phone || "01000000000",
        },
        paymentMethod: "Demo",
        paymentResult: {
          id: `demo_${Date.now()}`,
          status: "demo_succeeded",
          update_time: new Date().toISOString(),
          email_address: "demo@example.com",
        },
        itemsPrice,
        taxPrice,
        shippingPrice,
        totalPrice: totalAmount,
        isPaid: true,
        paidAt: new Date(),
      });

      dispatch(clearCart());
      toast.success("Order placed (demo payment)");
      navigate("/success");
    } catch (err) {
      const message = err.response?.data?.message || err.message;
      toast.error(`Order failed: ${message}`);
    } finally {
      setIsProcessing(false);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="bg-gray-800 p-6 rounded-lg">
      <h3 className="text-xl text-white mb-2 flex items-center gap-2">
        <CreditCard size={20} /> Demo Payment
      </h3>
      <p className="text-slate-400 text-sm mb-4 flex items-center gap-2">
        <ShieldCheck size={16} className="text-emerald-400" />
        Stripe is not configured. This places the order without charging a card.
      </p>

      <button
        type="submit"
        disabled={isProcessing}
        className="w-full mt-2 bg-purple-600 hover:bg-purple-700 text-white font-bold py-2 px-4 rounded transition disabled:opacity-50"
      >
        {isProcessing ? "Processing..." : `Place Order ($${Number(totalAmount).toFixed(2)})`}
      </button>
    </form>
  );
};

export default MockCheckoutForm;
