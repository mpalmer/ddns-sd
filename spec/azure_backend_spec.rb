require_relative './spec_helper'

require 'ddnssd/backend/azure'

include Azure::Dns::Mgmt::V2018_03_01_preview
include Azure::Dns::Mgmt::V2018_03_01_preview::Models

describe DDNSSD::Backend::Azure do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BACKEND"         => "azure",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
      "DDNSSD_AZURE_RESOURCE_GROUP_NAME"     => "ddns-test",
      "DDNSSD_AZURE_ACCESS_TOKEN"     => { accessToken : "flibber",
                                           expiresOn: "2018-08-02 11:29:51.706962",
                                           subscription: "123123123-1234-1234-1234-1234123123123",
                                           tenant: "123123123-1234-1234-1234-1234123123123",
                                           tokenType: "Bearer"
                                         }.to_json,
    }
  end
  let(:env) { base_env }
  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:backend) { DDNSSD::Backend::Azure.new(config) }

  let(:az_client) { DnsManagementClient.new }
  let(:az_stubs) { {} }

  before(:each) do
    Azure::Dns::Mgmt.V2018_03_01_preview.config[:RecordSets] = { stub_responses: az_stubs }
    allow(DnsManagementClient).to receive(:new).and_return(az_client)
    allow(MsRest::TokenCredentials).to receive(:new).and_return(nil)
  end

  describe ".new" do
    context "without a RESOURCE_GROUP specified" do
      let(:env) { base_env.reject { |k, v| k == "DDNSSD_AZURE_RESOURCE_GROUP_NAME" } }

      it "raises an exception" do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end

    context "without an ACCESS_TOKEN specified" do
      let(:env) { base_env.reject { |k, v| k == "DDNSSD_AZURE_ACCESS_TOKEN" } }

      it "raises an exception" do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end
  end

  describe "#dns_records" do
    context "one page of records" do
      let(:az_stubs) do
        {
          list_by_dns_zone: azure_response_fixture("basic_response")
        }
      end

      it "asks for the records of the correct zone ID" do
        expect(az_client).to receive(:list_by_dns_zone).with(config.backend_config["RESOURCE_GROUP_NAME"], config.base_domain).and_call_original

        backend.dns_records
      end

      it "returns a list of DDNSSD::DNSRecord objects" do
        expect(backend.dns_records).to be_an(Array)
        expect(backend.dns_records.reject { |rr| DDNSSD::DNSRecord === rr }).to be_empty
        expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
      end

      it "returns A records" do
        expect(backend.dns_records.any? { |rr| rr.type == :A }).to be(true)
      end

      it "returns AAAA records" do
        expect(backend.dns_records.any? { |rr| rr.type == :AAAA }).to be(true)
      end

      it "returns CNAME records" do
        expect(backend.dns_records.any? { |rr| rr.type == :CNAME }).to be(true)
      end

      it "returns SRV records" do
        expect(backend.dns_records.any? { |rr| rr.type == :SRV }).to be(true)
      end

      it "returns TXT records" do
        expect(backend.dns_records.any? { |rr| rr.type == :TXT }).to be(true)
      end

      it "returns PTR records" do
        expect(backend.dns_records.any? { |rr| rr.type == :PTR }).to be(true)
      end

      it "does not return SOA records" do
        expect(backend.dns_records.any? { |rr| rr.type == :SOA }).to be(false)
      end

      it "does not return NS records" do
        expect(backend.dns_records.any? { |rr| rr.type == :NS }).to be(false)
      end
    end

    context "on other errors" do
      let(:az_stubs) do
        {
          list_by_dns_zone: 'FunkyError'
        }
      end

      before(:each) { allow(logger).to receive(:error) }

      it "logs the error" do
        expect(logger).to receive(:error)

        backend.dns_records
      end

      it "returns an empty list" do
        expect(backend.dns_records).to be_empty
      end
    end
  end

  describe "#publish_record" do
    let(:route53_stubs) do
      {
        change_resource_record_sets: {
          change_info: {
            id: "xyzzy",
            status: "PENDING",
            submitted_at: Time.now
          }
        }
      }
    end

    context "with an NS record" do
      it "raises an exception" do
        expect { backend.publish_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an A record" do
      it "upserts the A record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "flingle.example.com",
                        type: "A",
                        ttl: 42,
                        resource_records: [
                          { value: "192.0.2.42" }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :A, "192.0.2.42"))
      end
    end

    context "with a AAAA record" do
      it "upserts the AAAA record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "flingle.example.com",
                        type: "AAAA",
                        ttl: 42,
                        resource_records: [
                          { value: "2001:DB8::42" }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42"))
      end
    end

    context "with a CNAME record" do
      it "upserts the CNAME record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "db.example.com",
                        type: "CNAME",
                        ttl: 42,
                        resource_records: [
                          { value: "pgsql.host27.example.com" }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("db.example.com", 42, :CNAME, "pgsql.host27.example.com"))
      end
    end

    context "with a TXT record" do
      it "upserts the TXT record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "faff._http._tcp.example.com",
                        type: "TXT",
                        ttl: 42,
                        resource_records: [
                          { value: '"something \"funny\"" "this too"' }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :TXT, 'something "funny"', "this too"))
      end
    end

    context "with a SRV record" do
      context "no existing recordset" do
        it "creates a new SRV record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 80, "faff.host22.example.com"))
        end
      end

      context "with existing records for the name/type" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 80, "faff.host1.example.com"),
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host3.example.com")
          )
        end

        it "adds a SRV record to the existing recordset" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" },
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 80, "faff.host22.example.com"))
        end
      end

      context "with the record already existent" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 80, "faff.host1.example.com"),
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host3.example.com"),
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 80, "faff.host22.example.com")
          )
        end

        it "makes sure we're up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" },
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" },
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 80, "faff.host22.example.com"))
        end
      end
    end

    context "with a PTR record" do
      context "no existing recordset" do
        it "creates a new PTR record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com"))
        end
      end

      context "with existing records for the name/type" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "xyzzy._http._tcp.example.com"),
            DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "argle._http._tcp.example.com")
          )
        end

        it "adds a PTR record to the existing recordset" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "xyzzy._http._tcp.example.com" },
                            { value: "argle._http._tcp.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "xyzzy._http._tcp.example.com" },
                            { value: "argle._http._tcp.example.com" },
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com"))
        end
      end

      context "including the one we want to add" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com")
          )
        end

        it "runs a no-change change to ensure everything's up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com"))
        end
      end

      context "on InvalidChangeBatch error" do
        let(:route53_stubs) do
          already_called = false
          {
            list_resource_record_sets: rr_list,
            change_resource_record_sets: ->(context) do
              unless already_called
                already_called = true
                'InvalidChangeBatch'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        context "with records appearing" do
          let(:rr_list) { route53_response_fixture("http_ptr") }

          it "refreshes the zone data and retries the request with the new values" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "_http._tcp.example.com", start_record_type: "PTR", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" },
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com"))
          end
        end

        context "with records disappearing" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "xyzzy._http._tcp.example.com"),
              DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "argle._http._tcp.example.com")
            )
          end

          let(:rr_list) { route53_response_fixture("some_other_record") }

          it "refreshes the zone data and retries the request with the new values" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" },
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "_http._tcp.example.com", start_record_type: "PTR", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(r53).to_not receive(:list_resource_record_sets).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com"))
          end
        end
      end
    end
  end

  describe "#suppress_record" do
    context "with an A record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.42")
          )
        end

        it "deletes the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.42" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.42"),
            DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.180")
          )
        end

        it "modifies the record set to remove our record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.42" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.42"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.180")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle.example.com", 42, :A, "192.0.2.42"))
        end
      end
    end

    context "with a AAAA record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42")
          )
        end

        it "deletes the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::42" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::1"),
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42"),
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::180")
          )
        end

        it "modifies the record set to remove our record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::42" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::1"),
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::180")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42"))
        end
      end
    end

    context "with a CNAME record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host42.example.com")
          )
        end

        it "deletes the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host42.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host42.example.com"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host1.example.com"),
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host42.example.com"),
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host180.example.com")
          )
        end

        it "modifies the record set to remove our record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host42.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host42.example.com"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host1.example.com"),
            DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host180.example.com")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle.example.com", 42, :CNAME, "host42.example.com"))
        end
      end
    end

    context "with a SRV record" do
      context "with other SRV records present" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host1.example.com"),
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host2.example.com")
          )
        end

        it "deletes our SRV record from the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 8080 host1.example.com" },
                            { value: "0 0 8080 host2.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 8080 host1.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host2.example.com"))
        end
      end

      context "with no other SRV records present" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host1.example.com")
          )
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :TXT, "something funny")
          )
        end

        context "with no other PTR records" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com")
            )
          end

          it "deletes the SRV, TXT, and PTR record sets" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 8080 host1.example.com" }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "TXT",
                            ttl: 42,
                            resource_records: [
                              { value: '"something funny"' }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets)

            backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host1.example.com"))
          end
        end

        context "with other PTR records" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "blargh._http._tcp.example.com"),
              DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com")
            )
          end

          it "deletes the SRV and TXT record sets, and prunes our record from the PTR record set" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 8080 host1.example.com" }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "TXT",
                            ttl: 42,
                            resource_records: [
                              { value: '"something funny"' }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "blargh._http._tcp.example.com" },
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "blargh._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets)

            backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :SRV, 0, 0, 8080, "host1.example.com"))
          end
      end
    end

    context "with a TXT record" do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x.example.com", 60, :TXT, "")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with a PTR record" do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x.example.com", 60, :PTR, "faff.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an NS record" do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "receiving any other error" do
      it "logs an error and gives up" do
        backend.instance_variable_get(:@record_cache).set(
          DDNSSD::DNSRecord.new("abcd1234.faff.example.com", 42, :A, "192.0.2.42")
        )
        expect(r53).to receive(:change_resource_record_sets).and_raise(RuntimeError)
        expect(logger).to receive(:error)

        backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.faff.example.com", 42, :A, "192.0.2.42"))
      end
    end
  end
end
