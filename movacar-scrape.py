#!/usr/bin/env python3
"""
Movacar Offer Scraper via Playwright.
Klickt "Find offers" und extrahiert alle verfügbaren Angebote.
"""
import json
import sys
from playwright.sync_api import sync_playwright

def scrape_movacar(origin=None, destination=None):
    url = "https://www.movacar.com/offers"
    params = []
    if origin:
        params.append(f"origin={origin}")
    if destination:
        params.append(f"destination={destination}")
    if params:
        url += "?" + "&".join(params)

    api_responses = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
        )
        page = context.new_page()

        # Capture XHR/Fetch responses
        def handle_response(response):
            url_lower = response.url.lower()
            if any(k in url_lower for k in ["firestore", "offer", "trip", "vehicle", "transfer", "api"]):
                try:
                    ct = response.headers.get("content-type", "")
                    if "json" in ct or "protobuf" in ct or "octet" in ct:
                        api_responses.append({
                            "url": response.url[:200],
                            "status": response.status,
                            "content_type": ct
                        })
                except:
                    pass

        page.on("response", handle_response)
        page.goto(url, wait_until="networkidle", timeout=30000)
        page.wait_for_timeout(3000)

        # Accept cookies if present
        try:
            page.click("text=Accept all", timeout=3000)
            page.wait_for_timeout(1000)
        except:
            pass

        # Click "Find offers" button
        try:
            page.click("text=Find offers", timeout=5000)
            page.wait_for_timeout(5000)
        except:
            pass

        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(3000)

        # Extract all visible content
        body_text = page.evaluate("() => document.body.innerText")

        browser.close()

    return {
        "url": url,
        "api_responses": api_responses,
        "body_text": body_text
    }


if __name__ == "__main__":
    origin = sys.argv[1] if len(sys.argv) > 1 else None
    destination = sys.argv[2] if len(sys.argv) > 2 else None

    print(f"Scraping movacar.com/offers (origin={origin}, dest={destination})...\n")
    result = scrape_movacar(origin, destination)

    if result["api_responses"]:
        print(f"{len(result['api_responses'])} API call(s) captured:")
        for r in result["api_responses"]:
            print(f"  {r['status']} {r['content_type'][:40]} {r['url']}")
        print()

    text = result["body_text"]
    # Filter out cookie banner noise
    for noise in ["We use cookies", "Your consent and the cookie policy"]:
        idx = text.find(noise)
        if idx > 0:
            text = text[:idx]

    print(text[:5000])
