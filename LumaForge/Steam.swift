import Foundation
import AuthenticationServices
import Security
import UIKit

struct SteamOpenID {
 static let endpoint="https://steamcommunity.com/openid/login"
 static func steamID(from callback:URL,expectedState:String)->String? {
  guard let c=URLComponents(url:callback,resolvingAgainstBaseURL:false) else{return nil}
  let q=Dictionary(uniqueKeysWithValues:(c.queryItems ?? []).compactMap{ $0.value.map{($0.name,$0)} })
  guard q["state"]==expectedState,q["openid.mode"]=="id_res",q["openid.op_endpoint"]==endpoint else{return nil}
  let id=q["openid.claimed_id"]?.split(separator:"/").last.map(String.init) ?? ""
  guard id.count==17,id.allSatisfy(\.isNumber),id.hasPrefix("7656119") else{return nil}; return id
 }
}
final class SteamKeychain {
 private let service="com.itzprovenom.lumaforge"
 func save(_ id:String){let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"steamID",kSecValueData as String:Data(id.utf8)];SecItemDelete(q as CFDictionary);SecItemAdd(q as CFDictionary,nil)}
 func load()->String?{let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"steamID",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne];var v:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&v)==errSecSuccess,let d=v as? Data else{return nil};return String(data:d,encoding:.utf8)}
 func clear(){SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"steamID"] as CFDictionary)}
}
@MainActor final class SteamSession:NSObject,ObservableObject,ASWebAuthenticationPresentationContextProviding {
 @Published private(set) var steamID:String?; @Published private(set) var signingIn=false
 private let keychain=SteamKeychain(); private var auth:ASWebAuthenticationSession?; private var state=""
 override init(){steamID=keychain.load();super.init()}
 func signIn(){guard !signingIn else{return};signingIn=true;state=UUID().uuidString;var c=URLComponents(string:SteamOpenID.endpoint)!;c.queryItems=[.init(name:"openid.ns",value:"http://specs.openid.net/auth/2.0"),.init(name:"openid.mode",value:"checkid_setup"),.init(name:"openid.return_to",value:"lumaforge://steam-callback?state=\(state)"),.init(name:"openid.realm",value:"lumaforge://"),.init(name:"openid.identity",value:"http://specs.openid.net/auth/2.0/identifier_select"),.init(name:"openid.claimed_id",value:"http://specs.openid.net/auth/2.0/identifier_select")];guard let url=c.url else{signingIn=false;return};let s=ASWebAuthenticationSession(url:url,callbackURLScheme:"lumaforge"){[weak self] callback,error in Task{@MainActor in guard let self else{return};defer{self.signingIn=false};guard error==nil,let callback,let id=SteamOpenID.steamID(from:callback,expectedState:self.state) else{return};if (try? await self.verify(callback)) == true {self.steamID=id;self.keychain.save(id)}}};s.presentationContextProvider=self;auth=s;s.start()}
 func signOut(){steamID=nil;keychain.clear()}
 private func verify(_ callback:URL) async throws->Bool{guard var c=URLComponents(url:callback,resolvingAgainstBaseURL:false) else{return false};var q=c.queryItems ?? [];q.removeAll{$0.name=="openid.mode"};q.append(.init(name:"openid.mode",value:"check_authentication"));c.queryItems=q;var r=URLRequest(url:URL(string:SteamOpenID.endpoint)!);r.httpMethod="POST";r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type");r.httpBody=c.percentEncodedQuery?.data(using:.utf8);let(d,res)=try await URLSession.shared.data(for:r);guard let h=res as? HTTPURLResponse,(200..<300).contains(h.statusCode) else{return false};return String(decoding:d,as:UTF8.self).range(of:#"(?im)^is_valid\s*:\s*true"#,options:.regularExpression) != nil}
 func presentationAnchor(for session:ASWebAuthenticationSession)->ASPresentationAnchor{UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap(\.windows).first(where:\.isKeyWindow) ?? ASPresentationAnchor()}
}