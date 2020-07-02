FROM dependabot/dependabot-core:0.118.6

# Create workspace
RUN mkdir -p /home/dependabot/
WORKDIR /home/dependabot/

# Install dependabot omnibus
COPY Gemfile .
RUN bundle install

# Copy scripts to run.
COPY azure_processor.rb .
COPY run.rb .

# Run script.
ENTRYPOINT ruby run.rb
