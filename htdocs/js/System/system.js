(() => {
	// Enable site-navigation menu toggling if the page has a site-navigation element.
	const navigation_element = document.getElementById('site-navigation');
	if (navigation_element) {
		const threshold = 768;
		let currentWidth = window.innerWidth;
		const content = document.getElementById('content');

		const toggleSidebar = () => {
			navigation_element.classList.toggle('toggle-width');
			navigation_element.classList.remove('invisible');
			content.classList.toggle('toggle-width');

			if (currentWidth < threshold) {
				const overlay = document.createElement('div');
				overlay.classList.add('sidebar-backdrop');
				document.body.append(overlay);
				overlay.addEventListener('click', () => {
					overlay.remove();
					navigation_element.classList.toggle('toggle-width');
					content.classList.toggle('toggle-width');
					document.body.classList.remove('no-scroll');
				});
				document.body.classList.add('no-scroll');
			}
		};

		document.getElementById('toggle-sidebar')?.addEventListener('click', toggleSidebar);

		if (currentWidth < threshold) navigation_element.classList.add('invisible');

		navigation_element.addEventListener('transitionend', () => {
			if (
				(window.innerWidth >= threshold && navigation_element.classList.contains('toggle-width')) ||
				(window.innerWidth < threshold && !navigation_element.classList.contains('toggle-width'))
			)
				navigation_element.classList.add('invisible');
		});

		// If the window width changes open or close the sidebar appropriately.
		window.addEventListener('resize', () => {
			if (!navigation_element.classList.contains('toggle-width') && window.innerWidth >= threshold)
				navigation_element.classList.remove('invisible');

			if (
				(navigation_element.classList.contains('toggle-width') &&
					window.innerWidth < threshold &&
					currentWidth >= threshold) ||
				(navigation_element.classList.contains('toggle-width') &&
					window.innerWidth >= threshold &&
					currentWidth < threshold)
			) {
				currentWidth = window.innerWidth;
				toggleSidebar();
				document.body.classList.remove('no-scroll');
				document.querySelectorAll('.sidebar-backdrop').forEach((overlay) => overlay.remove());
			}
			currentWidth = window.innerWidth;
		});
	}

	// Turn help boxes into popovers
	document.querySelectorAll('.help-popup').forEach((popover) => {
		popover.addEventListener('click', (e) => e.preventDefault());
		new bootstrap.Popover(popover, { trigger: 'hover focus' });
	});

	// Problem page popovers
	document
		.querySelectorAll('.student-nav-button')
		.forEach((el) => new bootstrap.Tooltip(el, { trigger: 'hover', fallbackPlacements: [] }));

	// Homework sets editor config
	// FIXME: These are really general purpose tooltips and not just in the homework sets editor.  So the class name
	// should be chosen to better reflect this.
	document.querySelectorAll('.set-id-tooltip').forEach((el) => {
		if (el.dataset.bsTitle) new bootstrap.Tooltip(el, { fallbackPlacements: [] });
	});

	// Hardcopy tooltips shown on the Problem Sets page.
	document
		.querySelectorAll('.hardcopy-tooltip')
		.forEach((el) => new bootstrap.Tooltip(el, { trigger: 'hover', fallbackPlacements: [], html: true }));

	const messages = document.querySelectorAll('#message .alert-dismissible, #message_bottom .alert-dismissible');
	if (messages.length) {
		const dismissBtn = document.getElementById('dismiss-messages-btn');
		dismissBtn?.classList.remove('d-none');

		// Hide the dismiss button when the last alert is dismissed.
		for (const message of messages) {
			message.addEventListener(
				'closed.bs.alert',
				() => {
					if (!document.querySelector('#message .alert-dismissible, #message_bottom .alert-dismissible'))
						dismissBtn.remove();
				},
				{ once: true }
			);
		}

		dismissBtn?.addEventListener('click', () =>
			messages.forEach((message) => bootstrap.Alert.getOrCreateInstance(message)?.close())
		);
	}
})();
