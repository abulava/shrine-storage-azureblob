# frozen_string_literal: true

require 'shrine'
require 'azure/storage/blob'
require 'content_disposition'

require 'uri'
require 'cgi'
require 'tempfile'

class Shrine
  module Storage
    class AzureBlob

      attr_reader :client, :account_name, :access_key, :container_name,
                  :multipart_threshold, :public, :scheme

      def initialize(account_name: nil, access_key: nil, container_name: nil, 
                     multipart_threshold: {}, public: nil, scheme: nil)
        @access_key = access_key
        @account_name = account_name
        @container_name = container_name
        @multipart_threshold = multipart_threshold
        @sas = Azure::Storage::Common::Core::Auth::SharedAccessSignature.new account_name, access_key
        @client = Azure::Storage::Blob::BlobService.create(
          storage_account_name: account_name,
          storage_access_key: access_key
        )
        @public = public
        @scheme = scheme || 'https'
      end

      def upload(io, id, shrine_metadata: {}, **_upload_options)
        content_type, filename = shrine_metadata.values_at('mime_type', 'filename')
        options = {}
        options[:content_type] = content_type if content_type
        options[:content_disposition] = ContentDisposition.inline(filename) if filename

        put(io, id, **options)
      end

      def extract_path(io)
        if io.respond_to?(:path)
          io.path
        elsif io.is_a?(UploadedFile) &&
              defined?(Storage::FileSystem) &&
              io.storage.is_a?(Storage::FileSystem)
          io.storage.path(io.id).to_s
        end
      end

      def open(id, _rewindable: false, **_options)
        GC.start
        _blob, content = @client.get_blob(container_name, id)
        StringIO.new(content)
      rescue Azure::Core::Http::HTTPError => e
        if e.status_code == 404
          raise Shrine::FileNotFound, "file #{id.inspect} not found on storage"
        else
          raise
        end
      end

      def put(io, id, **_options)
        if (path = extract_path(io))
          ::File.open(path, 'rb') do |file|
            @client.create_block_blob(container_name, id, file.read, timeout: 30, **_options)
          end
        else
          @client.create_block_blob(container_name, id, io.to_io, **_options)
        end
      end

      def delete(id)
        @client.delete_blob(container_name, id)
      end

      # :public
      # :  Returns the unsigned URL to the S3 object. This requires the S3
      #    object to be public.
      def url(id, public: self.public, scheme: self.scheme, **options)
        uri = @client.generate_uri("#{container_name}/#{id}")
        uri.scheme = scheme.to_s
        unless public
          uri.query = @sas.generate_service_sas_token(
            uri.path,
            service: 'b', # blob
            protocol: uri.scheme,
            permissions: 'r', # read
            **options # expiry: 30.minutes.from_now.to_s # as Time to string
          )
        end
        uri.to_s
      end

      class Tempfile < ::Tempfile
        attr_accessor :content_type
      end
    end
  end
end
