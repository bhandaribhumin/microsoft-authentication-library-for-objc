//------------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//------------------------------------------------------------------------------

#import "MSALAuthority.h"
#import "MSALError_Internal.h"
#import "MSALAadAuthorityResolver.h"
#import "MSALAdfsAuthorityResolver.h"
#import "MSALB2CAuthorityResolver.h"
#import "MSALHttpRequest.h"
#import "MSALHttpResponse.h"
#import "MSALURLSession.h"
#import "MSALTenantDiscoveryResponse.h"
#import "NSURL+MSALExtensions.h"

@implementation MSALAuthority

#define TENANT_ID_STRING_IN_PAYLOAD @"{tenantid}"

static NSSet<NSString *> *s_trustedHostList;
static NSMutableDictionary *s_validatedAuthorities;
static NSMutableDictionary *s_validatedUsersForAuthority;

#pragma mark - helper functions
+ (BOOL)isTenantless:(NSURL *)authority
{
    NSArray *authorityURLPaths = authority.pathComponents;
    
    NSString *tenameName = [authorityURLPaths[1] lowercaseString];
    if ([tenameName isEqualToString:@"common"] ||
        [tenameName isEqualToString:@"organizations"])
    {
        return YES;
    }
    return NO;
}

+ (NSURL *)cacheUrlForAuthority:(NSURL *)authority
                       tenantId:(NSString *)tenantId
{
    if (![MSALAuthority isTenantless:authority])
    {
        return authority;
    }
    
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/%@", [authority msalHostWithPort], tenantId]];
}


#pragma mark - class methods
+ (void)initialize
{
    s_trustedHostList = [NSSet setWithObjects: @"login.windows.net",
                         @"login.chinacloudapi.cn",
                         @"login-us.microsoftonline.com",
                         @"login.cloudgovapi.us",
                         @"login.microsoftonline.com",
                         @"login.microsoftonline.de", nil];
    
    s_validatedAuthorities = [NSMutableDictionary new];
    s_validatedUsersForAuthority = [NSMutableDictionary new];
}

+ (NSSet<NSString *> *)trustedHosts
{
    return s_trustedHostList;
}

+ (NSURL *)defaultAuthority
{
    return [NSURL URLWithString:@"https://login.microsoftonline.com/common"];
}

+ (NSURL *)checkAuthorityString:(NSString *)authority
                          error:(NSError * __autoreleasing *)error
{
    REQUIRED_STRING_PARAMETER(authority, nil);
    
    NSURL *authorityUrl = [NSURL URLWithString:authority];
    CHECK_ERROR_RETURN_NIL(authorityUrl, nil, MSALErrorInvalidParameter, @"\"authority\" must be a valid URI");
    CHECK_ERROR_RETURN_NIL([authorityUrl.scheme isEqualToString:@"https"], nil, MSALErrorInvalidParameter, @"authority must use HTTPS");
    CHECK_ERROR_RETURN_NIL((authorityUrl.pathComponents.count > 1), nil, MSALErrorInvalidParameter, @"authority must specify a tenant or common");
    
    // B2C
    if ([[authorityUrl.pathComponents[1] lowercaseString] isEqualToString:@"tfp"])
    {
        CHECK_ERROR_RETURN_NIL((authorityUrl.pathComponents.count > 3), nil, MSALErrorInvalidParameter,
                               @"B2C authority should have at least 3 segments in the path (i.e. https://<host>/tfp/<tenant>/<policy>/...)");
        
        NSString *updatedAuthorityString = [NSString stringWithFormat:@"https://%@/%@/%@/%@", [authorityUrl msalHostWithPort], authorityUrl.pathComponents[0], authorityUrl.pathComponents[1], authorityUrl.pathComponents[2]];
        return [NSURL URLWithString:updatedAuthorityString];
    }
    
    // ADFS and AAD
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/%@", [authorityUrl msalHostWithPort], authorityUrl.pathComponents[1]]];
}


+ (void)resolveEndpointsForAuthority:(NSURL *)unvalidatedAuthority
                   userPrincipalName:(NSString *)userPrincipalName
                            validate:(BOOL)validate
                             context:(id<MSALRequestContext>)context
                     completionBlock:(MSALAuthorityCompletion)completionBlock
{
    NSError *error = nil;
    NSURL *updatedAuthority = [self checkAuthorityString:unvalidatedAuthority.absoluteString error:&error];
    CHECK_COMPLETION(!error);
    
    MSALAuthorityType authorityType;
    NSString *firstPathComponent = updatedAuthority.pathComponents[1].lowercaseString;
    NSString *tenant = nil;
    
    id<MSALAuthorityResolver> resolver;
    
    if ([firstPathComponent isEqualToString:@"adfs"])
    {
        NSError *error = CREATE_LOG_ERROR(context, MSALErrorInvalidRequest, @"ADFS is not a supported authority");
        completionBlock(nil, error);
        return;
    }
    else if ([firstPathComponent isEqualToString:@"tfp"])
    {
        authorityType = B2CAuthority;
        resolver = [MSALB2CAuthorityResolver new];
        tenant = updatedAuthority.pathComponents[2].lowercaseString;
    }
    else
    {
        authorityType = AADAuthority;
        resolver = [MSALAadAuthorityResolver new];
        tenant = firstPathComponent;
    }
    
    MSALAuthority *authorityInCache = [MSALAuthority authorityFromCache:updatedAuthority userPrincipalName:userPrincipalName];
    
    if (authorityInCache)
    {
        completionBlock(authorityInCache, nil);
        return;
    }

    TenantDiscoveryCallback tenantDiscoveryCallback = ^void
    (MSALTenantDiscoveryResponse *response, NSError *error)
    {
        CHECK_COMPLETION(!error);

        MSALAuthority *authority = [MSALAuthority new];
        authority.canonicalAuthority = updatedAuthority;
        authority.authorityType = authorityType;
        authority.validateAuthority = validate;
        authority.isTenantless = [self isTenantless:updatedAuthority];
        
        // Only happens for AAD authority
        NSString *authorizationEndpoint = [response.authorization_endpoint stringByReplacingOccurrencesOfString:TENANT_ID_STRING_IN_PAYLOAD withString:tenant];
        NSString *tokenEndpoint = [response.token_endpoint stringByReplacingOccurrencesOfString:TENANT_ID_STRING_IN_PAYLOAD withString:tenant];
        NSString *issuer = [response.issuer stringByReplacingOccurrencesOfString:TENANT_ID_STRING_IN_PAYLOAD withString:tenant];
        
        authority.authorizationEndpoint = [NSURL URLWithString:authorizationEndpoint];
        authority.tokenEndpoint = [NSURL URLWithString:tokenEndpoint];
        authority.endSessionEndpoint = nil;
        authority.selfSignedJwtAudience = issuer;
     
        [MSALAuthority addToValidatedAuthority:authority userPrincipalName:userPrincipalName];
        
        completionBlock(authority, nil);
    };
    
    [resolver openIDConfigurationEndpointForAuthority:updatedAuthority
                                    userPrincipalName:userPrincipalName
                                             validate:validate
                                              context:context
                                      completionBlock:^(NSString *endpoint, NSError *error)
    {
        CHECK_COMPLETION(!error);
        
        [resolver tenantDiscoveryEndpoint:[NSURL URLWithString:endpoint]
                                  context:context completionBlock:tenantDiscoveryCallback];
        
    }];
}

+ (BOOL)isKnownHost:(NSURL *)url
{
    return [s_trustedHostList containsObject:url.host.lowercaseString];
}

+ (BOOL)addToValidatedAuthority:(MSALAuthority *)authority
              userPrincipalName:(NSString *)userPrincipalName
{
    if (!authority)
    {
        return NO;
    }
    
    if (!authority.canonicalAuthority ||
        (authority.authorityType == ADFSAuthority &&  [NSString msalIsStringNilOrBlank:userPrincipalName]))
    {
        return NO;
    }
    
    NSString *authorityKey = authority.canonicalAuthority.absoluteString;

    if (authority.authorityType == ADFSAuthority)
    {
        NSMutableSet<NSString *> *usersInDomain = s_validatedUsersForAuthority[authorityKey];
        if (!usersInDomain)
        {
            usersInDomain = [NSMutableSet new];
            s_validatedUsersForAuthority[authorityKey] = usersInDomain;
        }
        [usersInDomain addObject:userPrincipalName];
        
    }
    s_validatedAuthorities[authorityKey] = authority;

    return YES;
}

+ (MSALAuthority *)authorityFromCache:(NSURL *)authority
                    userPrincipalName:(NSString *)userPrincipalName
{
    if (!authority)
    {
        return nil;
    }
    
    NSString *authorityKey = authority.absoluteString;

    if (userPrincipalName)
    {
        NSSet *validatedUsers = s_validatedUsersForAuthority[authorityKey];
        if (![validatedUsers containsObject:userPrincipalName])
        {
            return nil;
        }
    }
    
    return s_validatedAuthorities[authorityKey];
}

@end
