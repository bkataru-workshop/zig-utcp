//! OAuth2 flow example
//! Demonstrates OAuth2 token acquisition and refresh

const std = @import("std");
const utcp = @import("utcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();  // Available for real OAuth2 calls

    std.debug.print("=== UTCP OAuth2 Flow Example ===\n\n", .{});

    // Note: This example demonstrates the OAuth2 API structure.
    // In production, you would use real credentials and a real OAuth2 server.

    // Example 1: Setting up OAuth2 provider
    std.debug.print("1. Setting up OAuth2 provider:\n", .{});
    {
        const provider = utcp.Provider{
            .id = "example_oauth_provider",
            .name = "Example OAuth2 API",
            .base_url = "https://api.example.com",
            .auth = .{
                .oauth2 = .{
                    .client_id = "your_client_id",
                    .client_secret = "your_client_secret",
                    .token_url = "https://auth.example.com/oauth/token",
                    .scope = "read write",
                },
            },
        };

        std.debug.print("   Provider: {s}\n", .{provider.name});
        std.debug.print("   Base URL: {?s}\n", .{provider.base_url});
        switch (provider.auth.?) {
            .oauth2 => |oauth| {
                std.debug.print("   OAuth2 Token URL: {s}\n", .{oauth.token_url});
                std.debug.print("   Scope: {?s}\n", .{oauth.scope});
            },
            else => {},
        }
        std.debug.print("\n", .{});
    }

    // Example 2: OAuth2 token structure
    std.debug.print("2. OAuth2 token response structure:\n", .{});
    {
        // This is what you'd get back from obtainOAuth2Token
        const token_response = utcp.OAuth2TokenResponse{
            .access_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
            .token_type = "Bearer",
            .expires_in = 3600,
            .refresh_token = "refresh_token_here",
            .scope = "read write",
        };

        std.debug.print("   Access Token: {s}...\n", .{token_response.access_token[0..20]});
        std.debug.print("   Token Type: {s}\n", .{token_response.token_type});
        std.debug.print("   Expires In: {?d} seconds\n", .{token_response.expires_in});
        std.debug.print("   Refresh Token: {?s}\n", .{token_response.refresh_token});
        std.debug.print("\n", .{});
    }

    // Example 3: Creating a provider with pre-existing token
    std.debug.print("3. Using pre-existing access token:\n", .{});
    {
        // If you already have an access token (e.g., from a previous auth flow)
        const provider_with_token = utcp.Provider{
            .id = "api_with_token",
            .name = "API with Token",
            .base_url = "https://api.example.com",
            .auth = .{
                .oauth2 = .{
                    .client_id = "client_id",
                    .client_secret = "client_secret",
                    .token_url = "https://auth.example.com/token",
                    .access_token = "existing_access_token",
                    .refresh_token = "existing_refresh_token",
                },
            },
        };

        switch (provider_with_token.auth.?) {
            .oauth2 => |oauth| {
                std.debug.print("   Has access token: {}\n", .{oauth.access_token != null});
                std.debug.print("   Has refresh token: {}\n", .{oauth.refresh_token != null});
            },
            else => {},
        }
        std.debug.print("\n", .{});
    }

    // Example 4: OAuth2 flow pseudocode
    std.debug.print("4. OAuth2 flow overview:\n", .{});
    std.debug.print(
        \\
        \\   Step 1: Create transport
        \\     var transport = utcp.HttpTransport.init(allocator);
        \\   
        \\   Step 2: Obtain initial token
        \\     const oauth_config = utcp.OAuth2Auth...
        \\     const token = try transport.obtainOAuth2Token(oauth_config);
        \\   
        \\   Step 3: Use the token
        \\     const provider = utcp.Provider...
        \\   
        \\   Step 4: Make API calls
        \\     const response = try transport.call(tool, request, provider);
        \\   
        \\   Step 5: Refresh token when expired
        \\     if (token_expired) ...
        \\       const new_token = try transport.refreshOAuth2Token(...)
        \\
    ++ "\n", .{});

    std.debug.print("\n=== OAuth2 Example Complete ===\n", .{});

    // Example 5: Demonstrate actual OAuth2 flow (commented out as it needs real credentials)
    std.debug.print("\n5. Live OAuth2 flow (requires real credentials):\n", .{});
    std.debug.print("   To test with a real OAuth2 provider:\n", .{});
    std.debug.print("   1. Set OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET env vars\n", .{});
    std.debug.print("   2. Uncomment the code below\n", .{});
    std.debug.print("   3. Run the example\n\n", .{});

    // Uncomment to test with real OAuth2 provider:
    // var transport = utcp.HttpTransport.init(allocator);
    // defer transport.deinit();
    // try transport.loadEnv();
    //
    // if (transport.env_map) |env| {
    //     if (env.get("OAUTH_CLIENT_ID")) |client_id| {
    //         const oauth_config = utcp.OAuth2Auth{
    //             .client_id = client_id,
    //             .client_secret = env.get("OAUTH_CLIENT_SECRET"),
    //             .token_url = env.get("OAUTH_TOKEN_URL") orelse "https://oauth2.googleapis.com/token",
    //         };
    //
    //         std.debug.print("   Attempting to obtain token...\n", .{});
    //         if (transport.obtainOAuth2Token(oauth_config)) |token| {
    //             std.debug.print("   Success! Token type: {s}\n", .{token.token_type});
    //             std.debug.print("   Expires in: {?d} seconds\n", .{token.expires_in});
    //         } else |err| {
    //             std.debug.print("   Failed: {}\n", .{err});
    //         }
    //     }
    // }
}
