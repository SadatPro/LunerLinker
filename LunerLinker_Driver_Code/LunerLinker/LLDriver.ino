// Fixed LunerLinker ESP32: Improved reliability and connection handling
#include <WiFi.h>
#include <LoRa.h>
#include <ArduinoJson.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>

// LoRa pins
#define LORA_CS_PIN    5
#define LORA_RST_PIN   14
#define LORA_IRQ_PIN   26
#define LORA_SCK_PIN   18
#define LORA_MISO_PIN  19
#define LORA_MOSI_PIN  23

// WiFi credentials
const char* ssid = "LunerLinker_02";
const char* password = "password123";

// LoRa frequency
#define LORA_FREQ 915E6

AsyncWebServer server(80);

// Improved message storage with circular buffer
#define MAX_MESSAGES 50
struct Message {
  String content;
  unsigned long timestamp;
  int rssi;
};

Message messages[MAX_MESSAGES];
int messageHead = 0;
int messageCount = 0;

// Connection tracking
unsigned long lastActivity = 0;
bool loraInitialized = false;

void addMessage(String content, int rssi = 0) {
  messages[messageHead].content = content;
  messages[messageHead].timestamp = millis();
  messages[messageHead].rssi = rssi;
  
  messageHead = (messageHead + 1) % MAX_MESSAGES;
  if (messageCount < MAX_MESSAGES) {
    messageCount++;
  }
  
  lastActivity = millis();
  Serial.printf("[MSG] Added: %s (Total: %d)\n", content.c_str(), messageCount);
}

void initializeLoRa() {
  Serial.println("[LoRa] Initializing...");
  
  // Reset LoRa module
  digitalWrite(LORA_RST_PIN, LOW);
  delay(10);
  digitalWrite(LORA_RST_PIN, HIGH);
  delay(10);
  
  SPI.begin(LORA_SCK_PIN, LORA_MISO_PIN, LORA_MOSI_PIN);
  LoRa.setPins(LORA_CS_PIN, LORA_RST_PIN, LORA_IRQ_PIN);

  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println("[LoRa] FAILED - Retrying in 2 seconds...");
    delay(2000);
    ESP.restart();
  }

  // Optimized settings for reliability
  LoRa.setSpreadingFactor(8);        // Better range/reliability
  LoRa.setSignalBandwidth(125E3);
  LoRa.setTxPower(20);
  LoRa.setCodingRate4(5);            // Error correction
  LoRa.setPreambleLength(8);
  LoRa.setSyncWord(0x12);            // Avoid interference
  LoRa.enableCrc();                  // Error detection
  e:\LunerLinker\LunerLinker_Driver_Code\LunerLinker.ino.txt
  LoRa.onReceive(onReceive);
  LoRa.receive();
  
  loraInitialized = true;
  Serial.println("[LoRa] Initialized successfully");
}

void setup() {
  Serial.begin(115200);
  Serial.println("\n[Boot] Enhanced LunerLinker starting...");

  // Initialize pins
  pinMode(LORA_RST_PIN, OUTPUT);
  
  // Initialize LoRa
  initializeLoRa();

  // Start WiFi Access Point with better settings
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(
    IPAddress(192, 168, 4, 1),
    IPAddress(192, 168, 4, 1),
    IPAddress(255, 255, 255, 0)
  );
  
  if (WiFi.softAP(ssid, password, 1, 0, 8)) { // Channel 1, not hidden, max 8 clients
    Serial.println("[WiFi] AP started");
    Serial.printf("[WiFi] IP: %s\n", WiFi.softAPIP().toString().c_str());
  }

  // Enhanced web server routes
  
  // Status endpoint with more info
  server.on("/status", HTTP_GET, [](AsyncWebServerRequest *request){
    StaticJsonDocument<300> status;
    status["status"] = "ok";
    status["uptime"] = millis();
    status["messages"] = messageCount;
    status["lora_initialized"] = loraInitialized;
    status["wifi_clients"] = WiFi.softAPgetStationNum();
    status["last_activity"] = lastActivity;
    status["free_heap"] = ESP.getFreeHeap();
    
    String response;
    serializeJson(status, response);
    
    AsyncWebServerResponse *resp = request->beginResponse(200, "application/json", response);
    resp->addHeader("Cache-Control", "no-cache");
    request->send(resp);
  });

  // Get messages with improved handling
  server.on("/getMessages", HTTP_GET, [](AsyncWebServerRequest *request){
    if (messageCount == 0) {
      request->send(200, "application/json", "[]");
      return;
    }
    
    const size_t capacity = JSON_ARRAY_SIZE(messageCount) + messageCount * JSON_OBJECT_SIZE(3) + 1024;
    DynamicJsonDocument doc(capacity);
    JsonArray messageArray = doc.to<JsonArray>();
    
    // Read messages in correct order
    int startIdx = (messageCount < MAX_MESSAGES) ? 0 : messageHead;
    for (int i = 0; i < messageCount; i++) {
      int idx = (startIdx + i) % MAX_MESSAGES;
      JsonObject msg = messageArray.createNestedObject();
      msg["content"] = messages[idx].content;
      msg["timestamp"] = messages[idx].timestamp;
      msg["rssi"] = messages[idx].rssi;
    }
    
    String response;
    serializeJson(messageArray, response);
    
    AsyncWebServerResponse *resp = request->beginResponse(200, "application/json", response);
    resp->addHeader("Cache-Control", "no-cache");
    request->send(resp);
    
    // Clear messages after sending
    messageCount = 0;
    messageHead = 0;
    Serial.println("[HTTP] Messages cleared after sending");
  });

  // Handle CORS preflight
  server.on("/sendMessage", HTTP_OPTIONS, [](AsyncWebServerRequest *request){
    AsyncWebServerResponse *response = request->beginResponse(200);
    response->addHeader("Access-Control-Allow-Origin", "*");
    response->addHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    response->addHeader("Access-Control-Allow-Headers", "Content-Type");
    request->send(response);
  });

  // Send message with improved error handling
  server.on("/sendMessage", HTTP_POST, [](AsyncWebServerRequest *request){}, NULL,
    [](AsyncWebServerRequest *request, uint8_t *data, size_t len, size_t index, size_t total){
      if (!loraInitialized) {
        request->send(503, "text/plain", "LoRa not initialized");
        return;
      }
      
      StaticJsonDocument<300> doc;
      DeserializationError err = deserializeJson(doc, data, len);
      
      if (err) {
        Serial.printf("[HTTP] JSON Error: %s\n", err.c_str());
        request->send(400, "text/plain", "Invalid JSON");
        return;
      }
      
      String content = doc["content"] | "";
      
      if (content.length() == 0 || content.length() > 200) {
        request->send(400, "text/plain", "Content required (1-200 chars)");
        return;
      }
      
      // Send via LoRa with retry mechanism
      bool sent = false;
      for (int attempt = 0; attempt < 3 && !sent; attempt++) {
        LoRa.idle(); // Ensure we're not in receive mode
        delay(10);
        
        LoRa.beginPacket();
        LoRa.print(content);
        int result = LoRa.endPacket(false); // Non-blocking
        
        if (result == 1) {
          sent = true;
          Serial.printf("[LoRa TX] %s (Attempt %d)\n", content.c_str(), attempt + 1);
        } else {
          Serial.printf("[LoRa TX] Failed attempt %d\n", attempt + 1);
          delay(50);
        }
      }
      
      // Return to receive mode
      delay(100);
      LoRa.receive();
      
      if (sent) {
        AsyncWebServerResponse *resp = request->beginResponse(200, "text/plain", "Message sent");
        resp->addHeader("Access-Control-Allow-Origin", "*");
        request->send(resp);
      } else {
        AsyncWebServerResponse *resp = request->beginResponse(500, "text/plain", "Send failed after retries");
        resp->addHeader("Access-Control-Allow-Origin", "*");
        request->send(resp);
      }
    }
  );

  // Add global CORS headers
  DefaultHeaders::Instance().addHeader("Access-Control-Allow-Origin", "*");
  DefaultHeaders::Instance().addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  DefaultHeaders::Instance().addHeader("Access-Control-Allow-Headers", "Content-Type");

  // 404 handler
  server.onNotFound([](AsyncWebServerRequest *request){
    request->send(404, "text/plain", "Not Found");
  });

  server.begin();
  Serial.println("[HTTP] Web server started");
  
  Serial.println("\n=== Enhanced LunerLinker Ready ===");
  Serial.printf("WiFi: %s\n", ssid);
  Serial.printf("IP: http://%s\n", WiFi.softAPIP().toString().c_str());
  Serial.println("===================================\n");
}

void loop() {
  // Monitor system health
  static unsigned long lastHealthCheck = 0;
  if (millis() - lastHealthCheck > 30000) { // Every 30 seconds
    Serial.printf("[Health] Heap: %d, Clients: %d, Messages: %d\n", 
                  ESP.getFreeHeap(), WiFi.softAPgetStationNum(), messageCount);
    lastHealthCheck = millis();
    
    // Restart LoRa if it seems stuck
    if (loraInitialized && millis() - lastActivity > 300000) { // 5 minutes
      Serial.println("[Health] LoRa seems inactive, reinitializing...");
      initializeLoRa();
    }
  }
  
  // Handle WiFi client connections
  static int lastClientCount = -1;
  int currentClients = WiFi.softAPgetStationNum();
  if (currentClients != lastClientCount) {
    Serial.printf("[WiFi] Clients: %d\n", currentClients);
    lastClientCount = currentClients;
  }
  
  delay(100);
}

void onReceive(int packetSize) {
  if (packetSize == 0) return;

  String incoming = "";
  while (LoRa.available()) {
    incoming += (char)LoRa.read();
  }

  // Filter out empty or corrupted messages
  incoming.trim();
  if (incoming.length() == 0 || incoming.length() > 200) {
    Serial.println("[LoRa RX] Invalid message ignored");
    LoRa.receive();
    return;
  }

  long rssi = LoRa.packetRssi();
  float snr = LoRa.packetSnr();
  
  Serial.printf("[LoRa RX] %s (RSSI: %ld, SNR: %.1f)\n", 
                incoming.c_str(), rssi, snr);

  // Add to message list
  addMessage(incoming, rssi);

  // Continue listening
  LoRa.receive();
}