import requests

# 1. Send the request to Binance API
url = "https://api.binance.com/api/v3/ticker/24hr?symbol=BTCUSDT"
response = requests.get(url)

# 2. Convert the response into a Python dictionary/list using .json()
data = response.json()

# 3. Print the ENTIRE raw data packet
print("--- Raw API Response ---")
print(data)

# 4. Or print a specific value (like just the price)
print("\n--- Specific Field ---")
print("Last Price:", data['lastPrice'])