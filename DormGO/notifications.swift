//
//  notifications.swift
//  KBTU Go
//
//  Created by Райымбек Омаров on 29.11.2024.
//
import SwiftUI
import SignalRClient
import Foundation


protocol ConnectionHandler: AnyObject {
    func restartConnection()
    func getCurrentToken() -> String?
}

struct PostDetails: Codable {
    let postId: String
    let description: String
    let currentPrice: Double
    let latitude: Double
    let longitude: Double
    let createdAt: String
    let maxPeople: Int
    let creator: ProtectedResponse
    let members: [ProtectedResponse]
}

struct PostResponse_Update: Codable {
    let message: String
    let post: PostDetails
}

struct PostCreate: Codable {
    let postId: String
    let title: String
    let createdAt: String
    let creatorName: String
    let maxPeople: Int
    let description :String
    // Extra fields not coming from JSON
    var currentPrice : Double = 0
    var latitude : Double = 0
    var longitude : Double = 0
    var creator: ProtectedResponse = ProtectedResponse(email: "", name: "")
    var members: [ProtectedResponse] = []

    enum CodingKeys: String, CodingKey {
        case postId = "id"
        case title = "title"
        case createdAt = "createdAt"
        case creatorName = "creatorName"
        case maxPeople = "maxPeople"
        case description = "description"
        // ⚠️ Don’t include isJoined or note here — so they won’t be decoded or encoded
    }
}
extension PostCreate {
    func toPost() -> Post {
        return Post(
            postId: self.postId,
            description: self.description,
            currentPrice: self.currentPrice,
            latitude: self.latitude, // ⚠️ typo here
            longitude: self.longitude,
            createdAt: self.createdAt,
            updatedAt: nil, // If you don’t have it, default to nil
            maxPeople: self.maxPeople,
            creator: self.creator,
            members: self.members
        )
    }
}
class CustomLogger: Logger {
    let dateFormatter: DateFormatter
    weak var connectionHandler: ConnectionHandler?

    init(connectionHandler: ConnectionHandler) {
        self.connectionHandler = connectionHandler
        dateFormatter = DateFormatter()
        // Keep existing date formatter setup
    }

    func log(logLevel: LogLevel, message: @autoclosure () -> String) {
        let logMessage = message()
        let timestamp = dateFormatter.string(from: Date())
        
        if logLevel == .error && logMessage.contains("401") {
            print("\(timestamp) ERROR: Unauthorized access detected (401).")
            PostAPIManager().refreshToken2 { success in
                if success {
                    print("Token refreshed. Restarting connection.")
                    self.connectionHandler?.restartConnection()
                }
            }
        } else {
            print("\(timestamp) \(logLevel.toString()): \(logMessage)")
        }
    }
}

class SignalRManager: ObservableObject, ConnectionHandler {
    func getCurrentToken() -> String? {
         return getJWTFromKeychain(tokenType: "access_token")
     }
    

    private var hubConnection: HubConnection?
//    @Published var posts: [PostDetails] = [] // State to hold the posts
//    @Published var posts_update: [PostDetails] = []
    private var customLogger: CustomLogger?
    
    var onPostCreated: ((PostCreate) -> Void)?
      var onPostUpdated: ((PostCreate) -> Void)?
      var onPostDeleted: ((String) -> Void)?
        init() {
            self.customLogger = CustomLogger(connectionHandler:  self)
            
            guard let logger = customLogger else {
                        fatalError("CustomLogger could not be initialized.")
                    }
        let hubUrl = endpoint("api/posthub")
        hubConnection = HubConnectionBuilder(url: hubUrl)
            .withHttpConnectionOptions { options in
                if let token = getJWTFromKeychain(tokenType: "access_token") {
                    options.accessTokenProvider = { token }
                }
            }
            .withLogging(minLogLevel: .error,logger:  logger)
            .build()
        
                  // Once listeners are set up, mark as ready
              
         // Register listeners for SignalR events
        
    }

    func startConnection() {
        guard let logger = customLogger else {
                   fatalError("CustomLogger could not be initialized.")
               }
//
//          //Rebuild connection with the provided token and custom logger
         self.hubConnection = HubConnectionBuilder(url: endpoint("api/posthub"))
             .withHttpConnectionOptions { options in
                 if let token = getJWTFromKeychain(tokenType: "access_token") {
                     options.accessTokenProvider = { token }
                 }
             }
             .withLogging(minLogLevel: .error, logger:  logger)
             .build()
         setupListeners()
//         // Start the connection
//         self.hubConnection?.start()
        guard hubConnection != nil else {
            print("HubConnection is not initialized")
            return
        }
        hubConnection?.start()
     }
    

    func stopConnection() {
        hubConnection?.stop()
    }

    private func handlemessage_pc(type:Bool,postDto:PostCreate){
        let timestamp = Date()
        print("Received post at \(timestamp) with type: \(type)")  // Log the time and type

        if !type {
            print("Post appended: \(postDto)")
            DispatchQueue.main.async {
                [weak self] in
                               self?.onPostCreated?(postDto)
            }
        } else {
            print("Post ignored due to type being true")
        }
    }
    
   
    private func setupListeners() {
       // let hubUrl = endpoint("api/posthub")
        
    
        hubConnection?.on(method: "PostCreated", callback: { [weak self] (postDto: PostCreate) in
            guard let self = self else {
                
                print("Self is nil, cannot handle the post")
                return
            }
            self.onPostCreated?(postDto)
            // Handle the postDto here
            print("New post created: \(postDto)")
        })
        
        hubConnection?.on(method: "PostUpdated", callback: { [weak self] ( postDto: PostCreate) in
         
         //   print("Received post update at \(timestamp) with message: \(postDto.message)") // Log the time and type

      
                            DispatchQueue.main.async { [weak self] in
                                self?.onPostUpdated?(postDto)
                            }
            
            
               
            
        })
        
        hubConnection?.on(method: "PostDeleted", callback: { [weak self] (postId: String) in
        
            print("Received post deletion with id: \(postId)")

            DispatchQueue.main.async { [weak self] in
                    self?.onPostDeleted?(postId)
                }
           
        })
  
    }

    private func refreshTokenIfNeeded(completion: @escaping (Bool) -> Void) {
      

        // Aways attempt to refresh the token
        refreshToken { success in
            completion(success)
        }
    }

    private func refreshToken(completion: @escaping (Bool) -> Void) {
        PostAPIManager().refreshToken2 { [weak self] success in
            if success {
                print("Token refreshed successfully. Restarting connection.")
                self?.restartConnection()
                completion(true)
            } else {
                print("Failed to refresh token. Cannot restart connection.")
               // completion(false)
            }
        }
    }

     func restartConnection() {
        if let newToken = getJWTFromKeychain(tokenType: "access_token") {
            hubConnection?.stop()

            // Delay the start of the new connection to ensure proper stopping of the old connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.hubConnection = HubConnectionBuilder(url: endpoint("api/posthub"))
                    .withHttpConnectionOptions { options in
                        options.accessTokenProvider = { newToken }
                    }
                    .withLogging(minLogLevel: .info)
                    .build()

             //   self.setupListeners()
                self.hubConnection?.start()  // Reconnect after token refresh
            }
        }
    }
    private func isTokenExpired(_ token: String) -> Bool {
        // Token expiration check logic (e.g., decoding token and checking expiry)
        return false  // Replace with actual expiration check
    }
}

let signalRManager = SignalRManager()
struct ConfirmationTokens {
    let userName: String
    let accessToken: String
    let refreshToken: String
}

class ConfirmationManager: ObservableObject {
    private var hubConnection: HubConnection?
    @Published var isAuthenticated: Bool = false
    @Published var errorMessage: String? = nil

    private var email: String?

    init(email: String="") {
        self.email = email
    }
    func setEmail(_ newEmail: String) {
            self.email = newEmail
        }
    func connectToServer() {
        guard let email = email else {
            print("Email is not set.")
            errorMessage = "Email is not set."
            return
        }

        let baseUrlString = endpoint("api/userhub")
        let hubUrlString = "\(baseUrlString)?userName=\(email)"
        
        guard let hubUrl = URL(string: hubUrlString) else {
            print("Invalid URL.")
            errorMessage = "Invalid URL."
            return
        }

        hubConnection = HubConnectionBuilder(url: hubUrl)
            .withLogging(minLogLevel: .debug)
            .build()

        setupListeners()
        hubConnection?.start()
    }

    func stopConnection() {
        hubConnection?.stop()
    }

 
    private func setupListeners() {
        hubConnection?.on(method: "EmailConfirmed", callback: { [weak self] (tokenData: TokenData) in
            guard let self = self else { return }

            print("Access Token: \(tokenData.accessToken)")
            print("Refresh Token: \(tokenData.refreshToken)")

            DispatchQueue.global().async {
                let isAccessTokenSaved = saveJWTToKeychain(token: tokenData.accessToken, tokenType: "access_token")
                let isRefreshTokenSaved = saveJWTToKeychain(token: tokenData.refreshToken, tokenType: "refresh_token")

                DispatchQueue.main.async {
                    if isAccessTokenSaved && isRefreshTokenSaved {
                        print("Tokens saved successfully!")
                        UserDefaults.standard.set(true, forKey: "isAuthenticated")
                        self.isAuthenticated = true
                    } else {
                        print("Error saving tokens.")
                        self.errorMessage = "Error saving tokens."
                    }
                }
            }
        })
    }
}



class ChatHub: ObservableObject , ConnectionHandler{
    private var hubConnection: HubConnection?
    private var customLogger: CustomLogger?
    
    var onMessageReceived: ((String, Message) -> Void)? // (postId, message)
    func getCurrentToken() -> String? {
           return getJWTFromKeychain(tokenType: "access_token")
       }
       
    private var postId: String

    init(postId: String) {
        self.postId = postId
        self.customLogger = CustomLogger(connectionHandler: self)
    }
    
    func startConnection() {
        print("start")
        guard let logger = customLogger else {
            fatalError("Logger not set")
        }


        let hubUrl = endpoint("api/chathub")
        self.hubConnection = HubConnectionBuilder(url: hubUrl)
            .withHttpConnectionOptions { options in
                if let token = getJWTFromKeychain(tokenType: "access_token") {
                    options.accessTokenProvider = { token }
                }
            }
            .withLogging(minLogLevel: .error, logger: logger)
            .build()
        
        setupListeners() // VERY IMPORTANT
        hubConnection?.start()
    }
    
    func stopConnection() {
        hubConnection?.stop()
    }
    
    private func setupListeners() {
        print("Setting up chat listeners...")
//        hubConnection?.on(method: "ReceiveMessage", callback: { args in
//            print("Raw args received:", args)
//        })
          hubConnection?.on(method: "ReceiveMessage", callback: { [weak self] (postId: String, message: Message) in
            print("tor")
            guard let self = self else {
                print("ChatHub: Self deallocated, cannot handle message")
                return
            }
            
            print("Received raw message for post \(postId): \(message)")
            self.handleIncomingMessage(postId: postId, message: message)
        })
    }

    private func handleIncomingMessage(postId: String, message: Message) {
        let timestamp = Date()
        print("[\(timestamp)] Received message for post \(postId)")
        
        DispatchQueue.main.async { [weak self] in
            self?.onMessageReceived?(postId, message)
            print("Processed message: \(message.content)")
        }
    }
    // Handle token refresh similar to SignalRManager if needed
     func restartConnection() {
        if let newToken = getJWTFromKeychain(tokenType: "access_token") {
            hubConnection?.stop()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.hubConnection = HubConnectionBuilder(url: endpoint("api/chathub"))
                    .withHttpConnectionOptions { options in
                        options.accessTokenProvider = { newToken }
                    }
                    .withLogging(minLogLevel: .error)
                    .build()
                
                self.setupListeners()
                self.hubConnection?.start()
            }
        }
    }
}


// MARK: - Data Models
struct Message: Identifiable, Decodable {
    let messageId: String
    let content: String
    let sender: Sender
    let sentAt: String
    let updatedAt: String?
    let post: Post // Include the related post

    // Conforming to Identifiable by using messageId as the ID
    var id: String { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId = "id" // map JSON "id" to property messageId
        case content, sender, sentAt, updatedAt, post
    }
}

struct Sender: Decodable {
    let email: String
    let name: String
    let id: String
}
struct ChatSender: Decodable {
    let userId: String
    let userName: String
}

struct TokenData: Codable {
    let accessToken: String
    let refreshToken: String
}
