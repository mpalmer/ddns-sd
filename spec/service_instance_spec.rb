require_relative './spec_helper'

require 'ddnssd/config'
require 'ddnssd/dns_record'
require 'ddnssd/service_instance'

describe DDNSSD::ServiceInstance do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
      "DDNSSD_BACKEND"         => "test_queue",
      "DDNSSD_HOST_IP_ADDRESS" => "192.0.2.42"
    }
  end
  let(:env) { base_env }

  let(:config) do
    DDNSSD::Config.new(
      env,
      logger: logger
    )
  end
  let(:container) { DDNSSD::Container.new(docker_container, config) }

  let(:instance) { DDNSSD::ServiceInstance.new("http", labels, container, config) }

  RSpec.shared_examples "a service instance error" do
    before(:each) { allow(logger).to receive(:error) }

    it "returns no records" do
      expect(instance.dns_records).to be_empty
    end

    it "logs an error" do
      instance.dns_records

      expect(logger).to have_received(:error)
    end
  end

  describe "#dns_records" do
    let(:result) { instance.dns_records('example.com') }

    context "with just a port label" do
      let(:labels) do
        {
          "port" => "80"
        }
      end

      context "with an exposed port" do
        let(:docker_container) { container_fixture("exposed_port80") }

        it "points to the container's IPv4 address" do
          expect(result).to have_A_record("asdfasdfexpo.speccy", "172.17.0.42")
        end

        it "points to the container's IPv6 address" do
          expect(result).to have_AAAA_record("asdfasdfexpo.speccy", "2001:db8::42")
        end

        it "has a SRV record pointing to the container+exposed port" do
          expect(result).to have_SRV_record("exposed80._http._tcp", "0 0 80 asdfasdfexpo.speccy.example.com")
        end

        it "has an empty TXT record" do
          expect(result).to have_TXT_record("exposed80._http._tcp", [""])
        end

        it "points to the service instance" do
          expect(result).to have_PTR_record("_http._tcp", "exposed80._http._tcp.example.com")
        end
      end

      context "with an exposed port and no IPv6 address" do
        let(:docker_container) { container_fixture("exposed_port80_v4only") }

        it "points to the container's IPv4 address" do
          expect(result).to have_A_record("asdfasdfexpo.speccy", "172.17.0.42")
        end

        it "does not have a AAAA record" do
          expect(result).to_not have_AAAA_record
        end

        it "has a SRV record pointing to the container+exposed port" do
          expect(result).to have_SRV_record("exposed80._http._tcp", "0 0 80 asdfasdfexpo.speccy.example.com")
        end

        it "has an empty TXT record" do
          expect(result).to have_TXT_record("exposed80._http._tcp", [""])
        end

        it "points to the service instance" do
          expect(result).to have_PTR_record("_http._tcp", "exposed80._http._tcp.example.com")
        end
      end

      context "with a published port and host IP address configured" do
        let(:docker_container) { container_fixture("published_port80") }

        it "doesn't ask to have the host's IPv4 address created" do
          expect(result).to_not have_A_record
        end

        it "has no IPv6 address" do
          expect(result).to_not have_AAAA_record
        end

        it "has a SRV record pointing to the host+published port" do
          expect(result).to have_SRV_record("pub80._http._tcp", "0 0 8080 speccy.example.com")
        end

        it "has an empty TXT record" do
          expect(result).to have_TXT_record("pub80._http._tcp", [""])
        end

        it "points to the service instance" do
          expect(result).to have_PTR_record("_http._tcp", "pub80._http._tcp.example.com")
        end
      end

      context "with a published port and specified IP address" do
        let(:docker_container) do
          container_fixture("published_port80").tap do |dc|
            dc.info["NetworkSettings"]["Ports"]["80/tcp"].first["HostIp"] = "192.0.2.99"
          end
        end

        it "points to the machine's IPv4 address" do
          expect(result).to have_A_record("192-0-2-99.speccy", "192.0.2.99")
        end

        it "has no IPv6 address" do
          expect(result).to_not have_AAAA_record
        end

        it "has a SRV record pointing to the host+published port" do
          expect(result).to have_SRV_record("pub80._http._tcp", "0 0 8080 192-0-2-99.speccy.example.com")
        end

        it "has an empty TXT record" do
          expect(result).to have_TXT_record("pub80._http._tcp", [""])
        end

        it "points to the service instance" do
          expect(result).to have_PTR_record("_http._tcp", "pub80._http._tcp.example.com")
        end
      end

      context "published port with no host IP address" do
        let(:docker_container) { container_fixture("published_port80") }
        let(:env) { base_env.tap { |e| e.delete("DDNSSD_HOST_IP_ADDRESS") } }

        it_behaves_like "a service instance error"
      end

      context "with a stopped container" do
        let(:docker_container) { container_fixture("stopped_container") }

        it "doesn't have any DNS records" do
          expect(result).to eq([])
        end
      end
    end

    context "with an instance label" do
      let(:labels) do
        {
          "port" => "80",
          "instance" => "flibbety"
        }
      end

      context "exposed port" do
        let(:docker_container) { container_fixture("exposed_port80") }

        it "has a SRV record pointing to the container+exposed port" do
          expect(result).to have_SRV_record("flibbety._http._tcp", "0 0 80 asdfasdfexpo.speccy.example.com")
        end

        it "has an empty TXT record" do
          expect(result).to have_TXT_record("flibbety._http._tcp", [""])
        end

        it "points to the service instance" do
          expect(result).to have_PTR_record("_http._tcp", "flibbety._http._tcp.example.com")
        end
      end

      context "published port" do
        let(:docker_container) { container_fixture("published_port80") }

        it "has a SRV record pointing to the host+published port" do
          expect(result).to have_SRV_record("flibbety._http._tcp", "0 0 8080 speccy.example.com")
        end

        it "has an empty TXT record" do
          expect(result).to have_TXT_record("flibbety._http._tcp", [""])
        end

        it "points to the service instance" do
          expect(result).to have_PTR_record("_http._tcp", "flibbety._http._tcp.example.com")
        end
      end
    end

    context "with an empty instance label" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port" => "80",
          "instance" => ""
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with an excessively long instance label" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port" => "80",
          "instance" => "flibbety" * 10
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with an unacceptable code point in the instance label" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port" => "80",
          "instance" => "\x02"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a non-UTF8-valid string in the instance label" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port" => "80",
          "instance" => "\xc0"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a protocol=udp label" do
      let(:docker_container) { container_fixture("published_port80") }
      let(:labels) do
        {
          "port" => "80",
          "protocol" => "udp"
        }
      end

      it "has a _udp SRV record" do
        expect(result).to have_SRV_record("pub80._http._udp", "0 0 8080 speccy.example.com")
      end

      it "has an empty _udp TXT record" do
        expect(result).to have_TXT_record("pub80._http._udp", [""])
      end

      it "points to the _udp service instance" do
        expect(result).to have_PTR_record("_http._udp", "pub80._http._udp.example.com")
      end
    end

    context "with a protocol=both label" do
      let(:docker_container) { container_fixture("published_port80") }
      let(:labels) do
        {
          "port" => "80",
          "protocol" => "both"
        }
      end

      %w{_tcp _udp}.each do |proto|
        it "has a #{proto} SRV record" do
          expect(result).to have_SRV_record("pub80._http.#{proto}", "0 0 8080 speccy.example.com")
        end

        it "has an empty #{proto} TXT record" do
          expect(result).to have_TXT_record("pub80._http.#{proto}", [""])
        end

        it "points to the #{proto} service instance" do
          expect(result).to have_PTR_record("_http.#{proto}", "pub80._http.#{proto}.example.com")
        end
      end
    end

    context "with an invalid protocol label" do
      let(:docker_container) { container_fixture("published_port80") }
      let(:labels) do
        {
          "port" => "80",
          "protocol" => "ohai!"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a priority label" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"     => "80",
          "priority" => "42"
        }
      end

      it "has a customised SRV record" do
        expect(result).to have_SRV_record("exposed80._http._tcp", "42 0 80 asdfasdfexpo.speccy.example.com")
      end
    end

    context "with a priority label that isn't a number" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"     => "80",
          "priority" => "over 9000"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a priority label that is too big" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"     => "80",
          "priority" => "10000000000"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a weight label" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"   => "80",
          "weight" => "42"
        }
      end

      it "has a customised SRV record" do
        expect(result).to have_SRV_record("exposed80._http._tcp", "0 42 80 asdfasdfexpo.speccy.example.com")
      end
    end

    context "with a weight label that isn't a number" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"   => "80",
          "weight" => "over 9000"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a weight label that is too big" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"   => "80",
          "weight" => "10000000000"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with some basic tag labels" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"     => "80",
          "tag.foo"  => "bar",
          "tag.baz"  => "wombat",
          "tag.zomg" => ""
        }
      end

      it "has the correct TXT record" do
        expect(result).to have_TXT_record("exposed80._http._tcp", ["foo=bar", "baz=wombat", "zomg="])
      end
    end

    context "with a txtvers tag label" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg"    => "inorite!"
        }
      end

      it "puts the txtvers tag first" do
        txt_records = result.select { |r| r.data.class == Resolv::DNS::Resource::IN::TXT }
        expect(txt_records.length).to eq(1)
        expect(txt_records.first.data.strings.first).to eq("txtvers=1")
      end
    end

    context "with a tag label whose key is empty" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"     => "80",
          "tag.foo"  => "bar",
          "tag."     => "kaboom",
          "tag.zomg" => "inorite!"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a tag label whose key has an equals sign" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg="   => "inorite!"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a tag label whose key has an invalid character" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg\n"  => "inorite!"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with some boolean tags" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg"    => "inorite!",
          "tags"        => "something\nfunny"
        }
      end

      it "has the correct label set" do
        expect(result).to have_TXT_record("exposed80._http._tcp", ["txtvers=1", "foo=bar", "zomg=inorite!", "something", "funny"])
      end

      it "puts the txtvers tag first" do
        txt_records = result.select { |r| r.data.class == Resolv::DNS::Resource::IN::TXT }
        expect(txt_records.length).to eq(1)
        expect(txt_records.first.data.strings.first).to eq("txtvers=1")
      end
    end

    context "with boolean tags containing an equals sign" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg"    => "inorite!",
          "tags"        => "something\nno=fair\nfunny"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with boolean tags containing an invalid character" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg"    => "inorite!",
          "tags"        => "something\nfu\rny"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with boolean tags containing an empty key" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg"    => "inorite!",
          "tags"        => "something\n\nfunny"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with an excessively long value" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port"        => "80",
          "tag.foo"     => "bar",
          "tag.txtvers" => "1",
          "tag.zomg"    => "x" * 255
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with an aliases label" do
      let(:labels) do
        {
          "port"    => "80",
          "aliases" => "some.thing.funny,pgsql-master"
        }
      end

      context "with an exposed port" do
        let(:docker_container) { container_fixture("exposed_port80") }

        it "creates CNAME records pointing to the container+exposed port" do
          expect(result).to have_CNAME_record("some.thing.funny", "asdfasdfexpo.speccy.example.com")
          expect(result).to have_CNAME_record("pgsql-master", "asdfasdfexpo.speccy.example.com")
        end
      end

      context "with a published port and host IP address configured" do
        let(:docker_container) { container_fixture("published_port80") }

        it "creates CNAME records pointing to the container+exposed port" do
          expect(result).to have_CNAME_record("some.thing.funny", "speccy.example.com")
          expect(result).to have_CNAME_record("pgsql-master", "speccy.example.com")
        end
      end

      context "with a published port and specified IP address" do
        let(:docker_container) do
          container_fixture("published_port80").tap do |dc|
            dc.info["NetworkSettings"]["Ports"]["80/tcp"].first["HostIp"] = "192.0.2.99"
          end
        end

        it "creates CNAME records pointing to the container+exposed port" do
          expect(result).to have_CNAME_record("some.thing.funny", "192-0-2-99.speccy.example.com")
          expect(result).to have_CNAME_record("pgsql-master", "192-0-2-99.speccy.example.com")
        end
      end
    end

    context "with a label on a non-exposed port" do
      let(:docker_container) { container_fixture("exposed_port80") }
      let(:labels) do
        {
          "port" => "1337"
        }
      end

      it_behaves_like "a service instance error"
    end

    context "with a different base_domain arg" do
      context "with a port and instance labels" do
        let(:labels) do
          {
            "port" => "80",
            "instance" => "flibbety"
          }
        end

        let(:result) { instance.dns_records('sd.example.com') }

        context "exposed port" do
          let(:docker_container) { container_fixture("exposed_port80") }

          it "has a SRV record pointing to the container+exposed port" do
            expect(result).to have_SRV_record("flibbety._http._tcp.sd", "0 0 80 asdfasdfexpo.speccy.sd.example.com")
          end

          it "has an empty TXT record" do
            expect(result).to have_TXT_record("flibbety._http._tcp.sd", [""])
          end

          it "points to the service instance" do
            expect(result).to have_PTR_record("_http._tcp.sd", "flibbety._http._tcp.sd.example.com")
          end
        end

        context "published port" do
          let(:docker_container) { container_fixture("published_port80") }

          it "has a SRV record pointing to the host+published port" do
            expect(result).to have_SRV_record("flibbety._http._tcp.sd", "0 0 8080 speccy.sd.example.com")
          end

          it "has an empty TXT record" do
            expect(result).to have_TXT_record("flibbety._http._tcp.sd", [""])
          end

          it "points to the service instance" do
            expect(result).to have_PTR_record("_http._tcp.sd", "flibbety._http._tcp.sd.example.com")
          end
        end
      end
    end

    context "with no base_domain arg" do
      context "with a port and instance labels" do
        let(:labels) do
          {
            "port" => "80",
            "instance" => "flibbety"
          }
        end

        let(:result) { instance.dns_records }

        context "exposed port" do
          let(:docker_container) { container_fixture("exposed_port80") }

          it "has a SRV record pointing to the container+exposed port" do
            expect(result).to have_SRV_record("flibbety._http._tcp", "0 0 80 asdfasdfexpo.speccy.example.com")
          end

          it "has an empty TXT record" do
            expect(result).to have_TXT_record("flibbety._http._tcp", [""])
          end

          it "points to the service instance" do
            expect(result).to have_PTR_record("_http._tcp", "flibbety._http._tcp.example.com")
          end
        end

        context "published port" do
          let(:docker_container) { container_fixture("published_port80") }

          it "has a SRV record pointing to the host+published port" do
            expect(result).to have_SRV_record("flibbety._http._tcp", "0 0 8080 speccy.example.com")
          end

          it "has an empty TXT record" do
            expect(result).to have_TXT_record("flibbety._http._tcp", [""])
          end

          it "points to the service instance" do
            expect(result).to have_PTR_record("_http._tcp", "flibbety._http._tcp.example.com")
          end
        end
      end
    end
  end
end
