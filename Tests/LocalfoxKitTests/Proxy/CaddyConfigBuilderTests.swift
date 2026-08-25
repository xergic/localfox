import Foundation
import Testing
@testable import LocalfoxKit

@Suite("building a Caddy configuration")
struct CaddyConfigBuilderTests {
    private let options = CaddyConfigBuilder.Options(
        httpPort: 8080,
        httpsPort: 8443,
        storageRoot: "/var/db/localfox/caddy",
        logPath: "/var/log/localfox/caddy.log",
        accessLogPath: "/var/log/localfox/access.log",
        adminSocketPath: "/var/run/localfox/caddy.sock",
        caID: "localfox",
        caName: "Localfox Local CA"
    )

    private var routes: [ProxyRoute] {
        [
            ProxyRoute(id: "web", domain: LocalDomain("wishfox.localhost")!, port: 3000)!,
            ProxyRoute(id: "api", domain: LocalDomain("api.wishfox.localhost")!, port: 4000)!
        ]
    }

    @Test("a configuration has stable golden JSON")
    // swiftlint:disable:next function_body_length
    func goldenJSON() throws {
        let data = try CaddyConfigBuilder(options: options).build(routes: routes)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"""
        {
          "admin" : {
            "config" : {
              "persist" : false
            },
            "listen" : "unix\/\/var\/run\/localfox\/caddy.sock"
          },
          "apps" : {
            "http" : {
              "http_port" : 8080,
              "https_port" : 8443,
              "servers" : {
                "http" : {
                  "automatic_https" : {
                    "disable_redirects" : true
                  },
                  "listen" : [
                    "127.0.0.1:8080",
                    "[::1]:8080"
                  ],
                  "routes" : [
                    {
                      "handle" : [
                        {
                          "handler" : "static_response",
                          "headers" : {
                            "Location" : [
                              "https:\/\/{http.request.host}{http.request.uri}"
                            ]
                          },
                          "status_code" : 308
                        }
                      ]
                    }
                  ]
                },
                "https" : {
                  "automatic_https" : {
                    "disable_redirects" : true
                  },
                  "idle_timeout" : "24h",
                  "listen" : [
                    "127.0.0.1:8443",
                    "[::1]:8443"
                  ],
                  "routes" : [
                    {
                      "@id" : "svc-api",
                      "handle" : [
                        {
                          "flush_interval" : -1,
                          "handler" : "reverse_proxy",
                          "headers" : {
                            "request" : {
                              "set" : {
                                "X-Forwarded-Host" : [
                                  "{http.request.host}"
                                ],
                                "X-Forwarded-Proto" : [
                                  "https"
                                ]
                              }
                            }
                          },
                          "stream_close_delay" : "5m",
                          "transport" : {
                            "protocol" : "http",
                            "versions" : [
                              "1.1"
                            ]
                          },
                          "upstreams" : [
                            {
                              "@id" : "svc-api-upstream",
                              "dial" : "127.0.0.1:4000"
                            }
                          ]
                        }
                      ],
                      "match" : [
                        {
                          "host" : [
                            "api.wishfox.localhost"
                          ]
                        }
                      ]
                    },
                    {
                      "@id" : "svc-web",
                      "handle" : [
                        {
                          "flush_interval" : -1,
                          "handler" : "reverse_proxy",
                          "headers" : {
                            "request" : {
                              "set" : {
                                "X-Forwarded-Host" : [
                                  "{http.request.host}"
                                ],
                                "X-Forwarded-Proto" : [
                                  "https"
                                ]
                              }
                            }
                          },
                          "stream_close_delay" : "5m",
                          "transport" : {
                            "protocol" : "http",
                            "versions" : [
                              "1.1"
                            ]
                          },
                          "upstreams" : [
                            {
                              "@id" : "svc-web-upstream",
                              "dial" : "127.0.0.1:3000"
                            }
                          ]
                        }
                      ],
                      "match" : [
                        {
                          "host" : [
                            "wishfox.localhost"
                          ]
                        }
                      ]
                    },
                    {
                      "handle" : [
                        {
                          "body" : "Localfox has no service for {http.request.host}.",
                          "handler" : "static_response",
                          "status_code" : 503
                        }
                      ]
                    }
                  ]
                }
              }
            },
            "pki" : {
              "certificate_authorities" : {
                "localfox" : {
                  "install_trust" : false,
                  "name" : "Localfox Local CA"
                }
              }
            },
            "tls" : {
              "automation" : {
                "policies" : [
                  {
                    "issuers" : [
                      {
                        "ca" : "localfox",
                        "module" : "internal"
                      }
                    ],
                    "subjects" : [
                      "api.wishfox.localhost",
                      "wishfox.localhost"
                    ]
                  }
                ]
              }
            }
          },
          "logging" : {
            "logs" : {
              "default" : {
                "encoder" : {
                  "format" : "json"
                },
                "writer" : {
                  "filename" : "\/var\/log\/localfox\/caddy.log",
                  "output" : "file"
                }
              }
            }
          },
          "storage" : {
            "module" : "file_system",
            "root" : "\/var\/db\/localfox\/caddy"
          }
        }
        """#)
    }

    /// A golden of the subtree that changes, rather than a second copy of the
    /// whole config: everything outside `logging` and the https server's `logs`
    /// is already covered by the golden above, and duplicating it would only
    /// give two places to update for an unrelated change.
    @Test("recording requests has stable golden JSON for the parts it changes")
    func goldenAccessLogJSON() throws {
        let config = try decoded(recordsRequests: true)
        let logging = try #require(config["logging"])
        #expect(try pretty(logging) == #"""
        {
          "logs" : {
            "access" : {
              "encoder" : {
                "format" : "json"
              },
              "include" : [
                "http.log.access.access"
              ],
              "writer" : {
                "filename" : "\/var\/log\/localfox\/access.log",
                "output" : "file",
                "roll" : true,
                "roll_keep" : 2,
                "roll_size_mb" : 10
              }
            },
            "default" : {
              "encoder" : {
                "format" : "json"
              },
              "exclude" : [
                "http.log.access.access"
              ],
              "writer" : {
                "filename" : "\/var\/log\/localfox\/caddy.log",
                "output" : "file"
              }
            }
          }
        }
        """#)

        let logs = try #require(try httpsServer(in: config)["logs"])
        #expect(try pretty(logs) == #"""
        {
          "default_logger_name" : "access"
        }
        """#)
    }

    /// Caddy sends an entry to every log whose filters accept it, so without the
    /// exclusion every request also lands in caddy.log and the diagnostics pane
    /// fills with traffic instead of proxy events.
    @Test("the default log excludes exactly what the access log includes")
    func partitionsTheTwoLogs() throws {
        let logs = try #require(try decoded(recordsRequests: true)["logging"] as? [String: Any])
        let table = try #require(logs["logs"] as? [String: [String: Any]])
        #expect(table["access"]?["include"] as? [String] == ["http.log.access.access"])
        #expect(table["default"]?["exclude"] as? [String] == ["http.log.access.access"])
    }

    /// Off means absent, not present and disabled. A config built with recording
    /// off must carry no trace of the feature at all.
    @Test("recording off leaves no logger, no exclusion and no access file")
    func recordingOffLeavesNoTrace() throws {
        let config = try decoded()
        #expect(try httpsServer(in: config)["logs"] == nil)
        let logging = try #require(config["logging"] as? [String: Any])
        let table = try #require(logging["logs"] as? [String: [String: Any]])
        #expect(table.keys.sorted() == ["default"])
        #expect(table["default"]?["exclude"] == nil)
        let json = try #require(String(
            data: CaddyConfigBuilder(options: options).build(routes: routes), encoding: .utf8
        ))
        #expect(!json.contains("access.log"))
    }

    @Test("identical routes produce identical bytes regardless of input order")
    func isDeterministic() throws {
        let builder = CaddyConfigBuilder(options: options)
        #expect(try builder.build(routes: routes) == builder.build(routes: routes))
        #expect(try builder.build(routes: routes) == builder.build(routes: routes.reversed()))
    }

    @Test("the configuration encodes every proxy safety requirement")
    func encodesSafetyRequirements() throws {
        let data = try CaddyConfigBuilder(options: options).build(routes: routes)
        let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let admin = try #require(config["admin"] as? [String: Any])
        #expect(admin["listen"] as? String == "unix//var/run/localfox/caddy.sock")
        #expect((admin["config"] as? [String: Any])?["persist"] as? Bool == false)

        let storage = try #require(config["storage"] as? [String: Any])
        #expect(storage["module"] as? String == "file_system")
        #expect(storage["root"] as? String == "/var/db/localfox/caddy")

        let apps = try #require(config["apps"] as? [String: Any])
        let http = try #require(apps["http"] as? [String: Any])
        let servers = try #require(http["servers"] as? [String: Any])
        let httpServer = try #require(servers["http"] as? [String: Any])
        let httpsServer = try #require(servers["https"] as? [String: Any])
        #expect(httpServer["listen"] as? [String] == ["127.0.0.1:8080", "[::1]:8080"])
        #expect(httpsServer["listen"] as? [String] == ["127.0.0.1:8443", "[::1]:8443"])
        #expect(httpsServer["idle_timeout"] as? String == "24h")

        let redirect = try #require((httpServer["routes"] as? [[String: Any]])?.first)
        let redirectHandler = try #require((redirect["handle"] as? [[String: Any]])?.first)
        #expect(redirectHandler["status_code"] as? Int == 308)
        #expect((redirectHandler["headers"] as? [String: [String]])?["Location"] == ["https://{http.request.host}{http.request.uri}"])

        let httpsRoutes = try #require(httpsServer["routes"] as? [[String: Any]])
        let apiRoute = try #require(httpsRoutes.first { $0["@id"] as? String == "svc-api" })
        #expect((apiRoute["match"] as? [[String: [String]]])?.first?["host"] == ["api.wishfox.localhost"])
        let proxy = try #require((apiRoute["handle"] as? [[String: Any]])?.first)
        #expect(proxy["flush_interval"] as? Int == -1)
        #expect(proxy["stream_close_delay"] as? String == "5m")
        #expect((proxy["transport"] as? [String: Any])?["versions"] as? [String] == ["1.1"])
        let headers = try #require(proxy["headers"] as? [String: Any])
        let request = try #require(headers["request"] as? [String: Any])
        let requestHeaders = try #require(request["set"] as? [String: [String]])
        #expect(requestHeaders["X-Forwarded-Proto"] == ["https"])
        #expect(requestHeaders["X-Forwarded-Host"] == ["{http.request.host}"])
        let upstream = try #require((proxy["upstreams"] as? [[String: Any]])?.first)
        #expect(upstream["@id"] as? String == "svc-api-upstream")
        #expect(upstream["dial"] as? String == "127.0.0.1:4000")

        let fallback = try #require(httpsRoutes.last)
        let fallbackHandler = try #require((fallback["handle"] as? [[String: Any]])?.first)
        #expect(fallbackHandler["status_code"] as? Int == 503)
        #expect((fallbackHandler["body"] as? String)?.contains("{http.request.host}") == true)

        let pki = try #require(apps["pki"] as? [String: Any])
        let authorities = try #require(pki["certificate_authorities"] as? [String: [String: Any]])
        #expect(authorities["localfox"]?["install_trust"] as? Bool == false)
        let tls = try #require(apps["tls"] as? [String: Any])
        let automation = try #require(tls["automation"] as? [String: Any])
        let policy = try #require((automation["policies"] as? [[String: Any]])?.first)
        #expect(policy["subjects"] as? [String] == ["api.wishfox.localhost", "wishfox.localhost"])
        let issuer = try #require((policy["issuers"] as? [[String: String]])?.first)
        #expect(issuer == ["module": "internal", "ca": "localfox"])
    }

    @Test("an upstream update has a surgical path and loopback-only body")
    func makesUpstreamPatch() throws {
        let route = try #require(routes.first { $0.id == "api" })
        #expect(CaddyConfigBuilder.upstreamAdminPath(for: route) == "/id/svc-api-upstream")
        let body = try CaddyConfigBuilder.upstreamPatchBody(port: 5000)
        #expect(String(data: body, encoding: .utf8) == "{\"dial\":\"127.0.0.1:5000\"}")
    }

    /// Caddy's automatic HTTPS adds its own redirect listener on the well-known
    /// port 80 unless told otherwise, so an unprivileged run died with
    /// "listening on 127.0.0.1:80: bind: permission denied" even though every
    /// listener in this config named 8080.
    @Test("the configured ports replace Caddy's well-known defaults")
    func declaresItsOwnPorts() throws {
        let object = try decoded()
        let apps = try #require(object["apps"] as? [String: Any])
        let http = try #require(apps["http"] as? [String: Any])
        #expect(http["http_port"] as? Int == 8080)
        #expect(http["https_port"] as? Int == 8443)
    }

    @Test("both servers refuse Caddy's automatic redirect listener")
    func disablesAutomaticRedirects() throws {
        let object = try decoded()
        let apps = try #require(object["apps"] as? [String: Any])
        let http = try #require(apps["http"] as? [String: Any])
        let servers = try #require(http["servers"] as? [String: Any])
        for (name, server) in servers {
            let entry = try #require(server as? [String: Any])
            let automatic = entry["automatic_https"] as? [String: Any]
            #expect(automatic?["disable_redirects"] as? Bool == true, "\(name) would bind a second listener")
        }
    }

    private func decoded(recordsRequests: Bool = false) throws -> [String: Any] {
        let data = try CaddyConfigBuilder(options: options)
            .build(routes: routes, recordsRequests: recordsRequests)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func httpsServer(in config: [String: Any]) throws -> [String: Any] {
        let apps = try #require(config["apps"] as? [String: Any])
        let http = try #require(apps["http"] as? [String: Any])
        let servers = try #require(http["servers"] as? [String: Any])
        return try #require(servers["https"] as? [String: Any])
    }

    private func pretty(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        return try #require(String(data: data, encoding: .utf8))
    }
}
