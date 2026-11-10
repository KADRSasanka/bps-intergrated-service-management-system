"use client";
import { useEffect, useState } from "react";

export default function Home() {
  const [result, setResult] = useState("loading...");

  useEffect(() => {
    fetch(`${process.env.NEXT_PUBLIC_API_URL}/health`)
      .then((r) => r.json())
      .then((d) => setResult(JSON.stringify(d)))
      .catch((e) => setResult("ERROR: " + e.message));
  }, []);

  return <main className="p-8 text-xl">API status: {result}</main>;
}